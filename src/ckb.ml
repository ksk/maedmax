(*** MODULES *****************************************************************)
module C = Cache
module F = Format
module L = List
module O = Overlap
module R = Rule
module A = Analytics
module S = Settings
module St = Strategy
module Ac = Theory.Ac
module Commutativity = Theory.Commutativity
module Lit = Literal
module NS = Nodes
module Logic = Settings.Logic
module T = Term
module Tr = Trace
module Sig = Signature
module Sub = Term.Sub

module SizeOrderedNode = struct
  type t = Lit.t
  let le l l' = Lit.size l <= Lit.size l'
end

module SizeQueue = UniqueHeap.Make(SizeOrderedNode)

(*** OPENS *******************************************************************)
open Prelude
open Settings

(*** EXCEPTIONS **************************************************************)
exception Restart of Lit.t list * bool

(*** TYPES *******************************************************************)
type lit = Lit.t

type theory_extension_state = {
  theory_extensions : lit list list list;
  iterations : int
}

type state = {
  context : Logic.context;
  equations : NS.t;
  size_queue : SizeQueue.t; (* equations sorted by size *)
  goals : NS.t;
  new_nodes : lit list;
  last_trss : (Literal.t list * int * Order.t) list;
  extension : theory_extension_state option
}

(*** GLOBALS *****************************************************************)
let settings = ref Settings.default
let heuristic = ref Settings.default_heuristic
let heuristics = ref []
let time_limit = ref 0.0

(* caching for search strategies*)
let redc : (int * int, bool) Hashtbl.t = Hashtbl.create 512;;
let reducible : (int, Logic.t) Hashtbl.t = Hashtbl.create 512;;
let rl_index : (Rule.t, int) Hashtbl.t = Hashtbl.create 128;;
let term_index : (Term.t, int) Hashtbl.t = Hashtbl.create 128;;

(* hash values of states *)
let hash_initial = ref 0;;
let hash_iteration = ref [0];;

(* map equation s=t to list of (rs, s'=t') where rewriting s=t with rs yields
   s'=t' *)
let rewrite_trace : (Rule.t, (Rules.t * Rule.t) list) Hashtbl.t =
  Hashtbl.create 512

let acx_rules = ref []

(*** FUNCTIONS ***************************************************************)
let set_settings s =
  settings := s;
  Select.settings := s
;;

let set_heuristic h =
  heuristic := h;
  Select.heuristic := h
;;

(* shorthands for settings *)
let termination_strategy _ = 
  match !heuristic.strategy with 
  | [] -> failwith "no termination strategy found"
  | (s, _, _, _, _) :: _ -> s
;;

let dps_used _ = St.has_dps (termination_strategy ())

let sat_allowed _ = !heuristic.mode <> OnlyUNSAT

let unsat_allowed _ = !heuristic.mode <> OnlySAT

let constraints _ =
  match !heuristic.strategy with
  | [] -> failwith "no constraints found"
  | (_, cs, _, _, _) :: _ -> cs
;;

let max_constraints _ =
 match !heuristic.strategy with
  | [] -> failwith "no max constraints found"
  | (_, _, ms, _, _) :: _ -> ms
;;

let strategy_limit _ =
 match !heuristic.strategy with
  | [] -> failwith "empty strategy list"
  | (_, _, _, i, _) :: _ -> i
;;

let selection_mode _ =
 match !heuristic.strategy with
  | [] -> failwith "empty strategy list"
  | (_, _, _, _, s) :: _ -> s
;;

let use_maxsat _ = max_constraints () <> []

let has_comp () = L.mem S.Comp (constraints ())

let has_cpred () = L.mem S.CPsRed (max_constraints ())

let debug d = !settings.debug >= d

let check_subsumption n = !heuristic.check_subsumption >= n

let nth_iteration n = !A.iterations mod n == 0

let pop_strategy _ = 
 if debug 2 then F.printf "pop strategy\n%!";
 match !heuristic.strategy with
  | [] -> failwith "no strategy left in pop"
  | [s] -> ()
  | _ :: ss -> set_heuristic { !heuristic with strategy = ss }
;;

let t_strategies _ = L.map (fun (ts,_,_,_,_) -> ts) !heuristic.strategy 

let normalize = Variant.normalize_rule

let set_extension s =
  let sign = !settings.signature in
  let cs = [Term.F (c, []) | c, a <- sign; a = 0] in
  let us = [u | u, a <- sign; a = 1] in
  let extensions f a =
    let xs = [Term.V i | i <- Listx.range 0 (a - 1)] in
    let uxs = [Term.F(f, [c]) | f <- us; c <- cs @ xs] in
    let f_xs = Term.F(f, xs) in
    [[Lit.make_axiom (f_xs, x)] | x <- cs @ xs @ uxs] @ [[]]
  in
  let sext = {
    theory_extensions = [extensions f a | f, a <- sign; a > 0];
    iterations = 0
  }
  in
  {s with extension = Some sext}
;;

let make_state c es gs = {
  context = c;
  equations = NS.of_list es;
  size_queue = SizeQueue.empty;
  goals = gs;
  new_nodes = es;
  last_trss = [];
  extension = None
}

let copy_state s = {
  context = s.context;
  equations = NS.copy s.equations;
  size_queue = s.size_queue;
  goals = NS.copy s.goals;
  new_nodes = s.new_nodes;
  last_trss = s.last_trss;
  extension = s.extension
}

let update_state s es gs = { s with
  equations = es;
  goals = gs
}

let store_remaining_nodes ctx ns gs =
  if has_comp () then
    NS.iter (fun n -> ignore (C.store_eq_var ctx (Lit.terms n))) ns;
  let ns = NS.smaller_than !heuristic.soft_bound_equations ns in
  let ns' = [n | n <- ns; not (NS.mem Select.all_nodes_set n)] in
  let ns_sized = [n, Lit.size n | n <- NS.sort_size ns' ] in
  (*Select.all_nodes := L.rev_append (L.rev !Select.all_nodes) ns_sized;
  ignore (NS.add_list ns' Select.all_nodes_set);*)
  Select.add_to_all_nodes (ns', ns_sized);
  let gs = NS.smaller_than !heuristic.soft_bound_goals gs in
  let gs_sized = [n, Lit.size n | n <- NS.sort_size gs] in
  Select.add_to_all_goals gs_sized;
  (*Select.all_goals := L.rev_append (L.rev !Select.all_goals) gs_sized*)
;;

let trace_cassociativity acs =
  let x = T.V 1 in
  let y = T.V 2 in
  let z = T.V 3 in
  let x', y' = T.V 4, T.V 5 in
  let add f =
    let assoc = T.F(f, [T.F(f, [x; y]); z]), T.F(f, [x; T.F(f, [y; z])]) in
    let comm = (T.F(f, [x'; y']), T.F(f, [y'; x'])) in
    let st = T.F(f, [T.F(f, [y; x]); z]), T.F(f, [x; T.F(f, [y; z])]) in
    let mu = Sub.add 4 y (Sub.add 5 x Sub.empty) in
    let st = normalize st in
    Tr.add_overlap st (comm, [0], assoc, mu);
    let ut = T.F(f, [y; T.F(f, [x; z])]), T.F(f, [x; T.F(f, [y; z])]) in
    let ut = normalize ut in
    Tr.add_rewrite ut st ([], [assoc,[],Sub.add 1 y (Sub.add 2 x Sub.empty)])
  in
  List.iter add acs
;;

let fix_group_params settings =
  let gs = Theory.Group.symbols [Lit.terms l | l <- settings.axioms] in
  let prec = List.fold_left (fun p (f,i,_) -> [i; f] :: p) [] gs in
  let params = {precedence = prec; weights = []} in
  {settings with order_params = if gs = [] then None else Some params}
;;

(* * REWRITING * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)
(* normalization of cs with TRS with index n. Returns pair (cs',ff) where ff
   are newly generated eqs and cs' \subseteq cs is set of irreducible eqs *)
let rewrite ?(max_size=0) ?(normalize=false) rewriter (cs : NS.t) =
  let t = Unix.gettimeofday () in
  (* skip exponential rewrite sequences with unfortunate orders *)
  let nf n =
    try Lit.rewriter_nf_with ~max_size:max_size n rewriter
    with Rewriter.Max_term_size_exceeded ->
      if unsat_allowed () then heuristic := { !heuristic with mode = OnlyUNSAT }
      else raise (Restart ([], false));
      None
  in
  let rewrite n (irrdcbl, news) =
    match nf n with
      | None ->
        let n' = if normalize then Lit.normalize n else n in
        if normalize then (
          if !(Settings.do_proof) = Some CPF then (
            let tn = if Lit.is_equality n then Tr.add_norm else Tr.add_norm_goal in
            tn (Lit.terms n) (Lit.terms n'))
          else if !(Settings.do_proof) = Some TPTP then
            Lit.LightTrace.add_rename n' n);
        (NS.add n' irrdcbl, news) (* no progress here *)
      | Some (nnews, rs) -> irrdcbl, NS.add_list nnews news
  in
  let res = NS.fold rewrite cs (NS.empty (), NS.empty ()) in
  A.t_rewrite := !A.t_rewrite +. (Unix.gettimeofday () -. t);
  res
;;

let reduced ?(max_size=0) ?(normalize=false) rr ns =
  let (irred, news) = rewrite ~max_size:max_size ~normalize:normalize rr ns in
  NS.add_all news irred
;;

let reduced_goals ?(normalize=false) rew gs =
  let t = Unix.gettimeofday () in
  if debug 2 then
    Format.printf "rewrite G:\n%a\n" NS.print gs;
  let bnd = !heuristic.hard_bound_goals in
  let gs_red = reduced ~max_size:bnd ~normalize:normalize rew gs in
  let thresh = NS.avg_size gs + 8 in
  let res =
    if NS.size gs_red < 10 then gs_red, NS.empty ()
    else NS.filter_out (fun n -> Lit.size n > thresh) gs_red
  in
  A.t_rewrite_goals := !A.t_rewrite_goals +. (Unix.gettimeofday () -. t);
  res
;;

let goal_cp_table : bool NS.H.t = NS.H.create 128

let reduced_goal_cps rew gs =
  if !heuristic.reduced_goal_cps(*not (!A.shape = Idrogeno || !A.shape = Carbonio || !A.shape = Ossigeno || !A.shape = Silicio)*) then
    reduced_goals ~normalize:true rew gs
  else (
    let gs' = NS.filter (fun g -> not (NS.mem goal_cp_table g) &&
                                Lit.size g < !heuristic.hard_bound_goals) gs in
    NS.iter (fun g -> ignore (NS.add g goal_cp_table)) gs';
    let res = reduced_goals ~normalize:true rew gs' in
    res)
;;

let interreduce rr =
  let rew = new Rewriter.rewriter !heuristic rr [] Order.default in
  rew#init ();
  let right_reduce (l,r) =
    let r', rs = try rew#nf r with Rewriter.Max_term_size_exceeded -> r, [] in
    if r <> r' && l <> r' then (
      if !(Settings.do_proof) = Some TPTP then
        Lit.LightTrace.add_rewrite (Lit.make_axiom (l,r'))
          (Lit.make_axiom (l, r)) ([], [r | r, _, _ <- rs])
      else if !(Settings.do_proof) = Some CPF then
        Tr.add_rewrite (normalize (l,r')) (l, r) ([],rs));
    (l,r')
  in
  let rr_hat = Listx.unique ((L.map right_reduce) rr) in
  let proper_enc l l' = Subst.enc l l' && not (Subst.enc l' l) in
  let nonred l = List.for_all (fun (l',r') -> not (proper_enc l l')) rr_hat in
  [ rl | rl <- rr_hat; nonred (fst rl)]
;;

(* * CRITICAL PAIRS  * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let eqs_for_overlaps ee =
  let ee' = NS.filter Lit.not_increasing (NS.symmetric ee) in
  NS.variant_free ee'
;;

let subsumption_ratios : float list ref = ref []

let equations_for_overlaps red irred all =
  let ee = if !A.shape = Magnesio && NS.size red < 15 then NS.add_all irred red else irred in
  let irr = NS.filter Lit.not_increasing (NS.symmetric ee) in
  if !A.iterations < 3 && !heuristic.full_CPs_with_axioms then
    NS.to_list (eqs_for_overlaps all)
  else
    let last3 =
      match !subsumption_ratios with
      | a :: b :: c :: d :: _ -> a +. b +. c +. d <= 3.
      | _ -> false
    in
    let check = check_subsumption 1 && (!A.iterations < 9 || last3) in
    let irr' = if check then NS.subsumption_free irr else irr in
    let r = float_of_int (NS.size irr') /. (float_of_int (NS.size irr)) in
    if debug 1 then
      Format.printf "subsumption check (ratio %.2f)\n%!" r;
    subsumption_ratios := r :: !subsumption_ratios;
    (*if r <= 0.3 then (* might be useful for GRP505 - GRP508 *)
      heuristic := {!heuristic with check_subsumption = 2};*)
    NS.to_list (eqs_for_overlaps irr')
;;

(* get overlaps for rules rr and equations aa *)
let overlaps only_new s rr aa =
  (* by default, do AC pruning *)
  let prune_AC = !heuristic.prune_AC || !A.iterations mod 2 <> 0 in
  let ns =
    if not !settings.unfailing then rr
    else
      let rr = Listset.diff rr !settings.norm in (* normalized *)
      let acs, cs = !settings.ac_syms, !settings.only_c_syms in
      let aa' = Listset.diff aa !acx_rules in
      let aa' = if prune_AC then NS.ac_equivalence_free acs aa' else aa' in
      let rr' = if prune_AC then NS.ac_equivalence_free acs rr else rr in
      let aa' = NS.c_equivalence_free cs aa' in
      let large_or_keep = A.last_cp_count () < 1000 || not prune_AC in
      let rr' = if large_or_keep then rr' else NS.c_equivalence_free cs rr' in
      rr' @ aa'
  in
  (* only proper overlaps with rules*)
  let ns' = !settings.norm @ ns in (* normalized rules only on one side of CP *)
  let ovl = new Overlapper.overlapper !heuristic ns' (L.map Lit.terms rr) in
  ovl#init ();
  let cpl = [cp | n <- ns'; cp <- ovl#cps ~only_new:only_new n] in
  NS.of_list cpl, ovl
;;

let overlaps ?(only_new=false) s rr = A.take_time A.t_overlap (overlaps only_new s rr)

(* Goal only as outer rule, compute CPs with equations.
   Use rr only if the goals are not ground (otherwise, goals with rr are
   covered by rewriting). *)
let overlaps_on rr aa gs =
  let gs_for_ols = NS.to_list (eqs_for_overlaps gs) in
  let goals_ground = List.for_all Rule.is_ground !settings.gs in
  let acs, cs = !settings.ac_syms, !settings.only_c_syms in
  let ns = if goals_ground then aa else rr @ aa in
  let ns' = NS.ac_equivalence_free acs (Listset.diff ns !acx_rules) in
  let ns' = NS.c_equivalence_free cs ns' in
  let ovl = new Overlapper.overlapper !heuristic [eq | eq <- ns'] (L.map Lit.terms rr) in
  ovl#init ();
  let cps2 = NS.of_list [cp | g <- gs_for_ols; cp <- ovl#cps ~only_new:true g] in
  cps2
;;

(* * SUCCESS CHECKS  * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)
let saturated state (rr, ee) rew (axs, cps, cps') =
  match cps' with
  | None -> None (* too many CPs generated *)
  | Some cps' -> (
  let ee' = Rules.subsumption_free ee in
  let str = termination_strategy () in
  let sys = rr, ee', rew#order in
  let cc = axs @ (NS.to_list cps @ (NS.to_list cps')) in
  let eqs = [ Lit.terms n | n <- cc; Lit.is_equality n ] in
  let eqs = L.filter (fun e -> not (L.mem e rr)) eqs in
  let j =
    (* skip if too many equations, except for large (AQL) systems *)
    if List.length eqs > 50 && L.length !settings.axioms < 90 then None
    else
      let joinable (s,t) = try fst (rew#nf s) =fst (rew#nf t) with _ -> false in
      let eqs = L.filter (fun e -> not (joinable e)) eqs in
      match Ground.all_joinable !settings state.context str sys eqs with 
      | None -> None
      | Some _ ->
        let to_axs = L.map Lit.make_axiom in
        let ee' = NS.to_list (eqs_for_overlaps (NS.of_list (to_axs ee))) in
        let cps = Overlap.cps (rr @ [Lit.terms e | e <- ee']) in
        Ground.all_joinable !settings state.context str sys cps
  in
  if debug 2 then Format.printf "saturated:%B\n%!" (j <> None);
  j)
;;

let rewrite_seq rew (s,t) (rss,rst) =
  let rec seq u = function
     [] -> []
   | ((l, r), p, sub) :: rs ->
     let v = Term.replace u (Term.substitute sub r) p in
     ((l, r), p, sub, v) :: (seq v rs)
  in
  seq s rss, seq t rst
;;

let solved_goal rewriter gs =
  let try_to_solve g =
    try
      let s,t = Lit.terms g in
      let s',rss = rewriter#nf s in
      let t',rst = rewriter#nf t in
      if s' = t' then
        Some ((s,t), rewrite_seq rewriter (s,t) (rss,rst), s', Sub.empty)
      else if Subst.unifiable s t then
        Some ((s,t), ([],[]), s, Subst.mgu s t)
      else None
    with Rewriter.Max_term_size_exceeded -> None
  in
  NS.fold (fun g -> function None -> try_to_solve g | r -> r) gs None
;;

let filter_eqs ee acs =
  let is_ac e = List.exists (Rule.equation_variant e) (Theory.Ac.eqs acs) in
  let ee' = List.sort (fun e e' -> compare (Rule.size e) (Rule.size e')) ee in
  let rec redundant ((s, t) as e) es =
    s = t || List.exists (Rule.equation_variant e) es ||
    (match s, t with
      | T.F (f, ss), T.F (g, ts) when f = g ->
        List.for_all (fun (si, ti) -> redundant (si, ti) es) (Listx.zip ss ts)
      | _ -> false) ||
    (Theory.Ac.equivalent acs e && not (is_ac e))
  in
  List.fold_left (fun es e -> if redundant e es then es else e :: es) [] ee'
;;

let succeeds state (rr,ee) rewriter cc ieqs gs =
  let rr = [Lit.terms r | r <- rr] in
  let ee = [Lit.terms e | e <- NS.to_list ee; Lit.is_equality e] in
  (*rewriter#add_more ee;
  let ee = L.map fst ee in*)
  if debug 2 then 
    Format.printf "success check R:\n%a\nE:\n%a\nG:\n%a\n%!"
      Rules.print rr Rules.print ee NS.print gs;
  match solved_goal rewriter gs with
    | Some (st, rseq, u, sigma) ->
      if unsat_allowed () then Some (UNSAT, Proof (st, rseq, u,sigma)) else None
    | None ->
      let joinable (s,t) =
        try fst (rewriter#nf s) = fst (rewriter#nf t)
        with Rewriter.Max_term_size_exceeded -> false  
      in
      if unsat_allowed () && L.exists joinable ieqs then (* joinable inequality axiom *)
        let e = L.find joinable ieqs in
        Some (UNSAT, Proof (e, ([],[]), fst e, Sub.empty))
      else if List.length ee > 40 then
        None (* saturation too expensive, or goals have been discarded *)
      else match saturated state (rr, ee) rewriter cc with
        | None when rr @ ee = [] && sat_allowed () -> Some (SAT, Completion [])
        | Some order -> (
          let ee = filter_eqs ee !settings.ac_syms in
          let gs_ground = L.for_all Lit.is_ground (NS.to_list gs) in
          let ee_nonground = L.for_all (fun e -> not (Rule.is_ground e)) ee in
          let orientable (s,t) = order#gt s t || order#gt t s in
          (* if an equation is orientable, wait one iteration ... *)
          let ee_sym = ee @ [s, t| t, s <- ee ] in
          if not gs_ground && L.for_all (fun e -> not (orientable e)) ee (*&&
            !(Settings.do_proof) = None*) then  (*no narrowing proof output yet *)
            Narrow.decide_goals !settings (rr, rewriter) ee_sym order !heuristic
          else if not (rr @ ee = [] || gs_ground) then None
          else (
            match !settings.gs with
            | [] ->
              if ee = [] && sat_allowed () then
                if !(Settings.do_proof) = None then Some (SAT, Completion rr)
                else Some (SAT, GroundCompletion (rr, [], order))
              else if ieqs = [] && ee_nonground && sat_allowed () then
                Some (SAT, GroundCompletion (rr, ee, order))
              else None 
            | [s,t] ->
                let (s', rss), (t', rst) = rewriter#nf s, rewriter#nf t in
                assert (s' <> t');
                let steps = rewrite_seq rewriter (s,t) (rss,rst) in
                Some (SAT, Disproof (rr, ee, order, steps))
            (* TODO: no more ieqs! transform into goals *)
            (*else if ieqs = [] && ee_nonground && sat_allowed () then
              Some (SAT, GroundCompletion (rr, ee, order))
            else if L.length ieqs = 1 && NS.is_empty gs &&
              !(Settings.do_proof) = None then
              Narrow.decide !settings rr ee_sym order ieqs !heuristic*)
            | _ ->  None
          ))
        | _ -> None
;;

let succeeds ctx re rew cc ie =
  A.take_time A.t_success_check (succeeds ctx re rew cc ie)
;;

(* * FIND TRSS  * * *  * * * * * * * * * * * * * * * * * * * * * * * * * * * *)
let (<|>) = Logic.(<|>)
let (<&>) = Logic.(<&>)
let (!!) = Logic.(!!)
let (<=>>) = Logic.(<=>>)
let (<>>) = Logic.Int.(<>>)

let c_maxcomp ctx cc =
 let oriented ((l,r),v) = v <|> (C.find_rule (r,l)) in
 L.iter (fun ((l,r),v) ->
   if l > r then Logic.assert_weighted (oriented ((l,r),v)) 1) cc
;;

let c_not_oriented ctx cc =
 let exp (l,r) = (!! (C.find_rule (l,r))) <&> (!! (C.find_rule (r,l))) in
 L.iter (fun rl -> Logic.assert_weighted (exp rl) 1) cc
;;

let term_idx r = 
  try Hashtbl.find term_index r
  with Not_found -> 
    let i = Hashtbl.length term_index in Hashtbl.add term_index r i; i
;;

let rule_idx r = 
  try Hashtbl.find rl_index r
  with Not_found -> 
    let i = Hashtbl.length rl_index in Hashtbl.add rl_index r i; i
;;

(* Returns constraint expressing reducibility of the term pair st using the
   rewrite rules stored in the reducibility checker rdc. The constraint is
   based on rule variables expressing presence of certain rewrite rules. *)
let rlred state rdc st =
  Logic.big_or state.context [rl | rl <- rdc#reducible_rule st]
;;

let c_red s ccl ccsym_vs =
  let ccym_vs = [(l,r),v | (l,r),v <- ccsym_vs; Term.size l >= Term.size r] in
  let rdc = new Rewriter.reducibility_checker ccym_vs in
  rdc#init None;
  L.iter (fun rl -> Logic.require (rlred s rdc rl)) ccl
;;

let c_red s ccl = A.take_time A.t_cred (c_red s ccl)

(* this heuristic uses rules only in a non-increasing way *)
let c_red_size s ccr cc_vs =
  let ccsym' = [ (l,r),v | (l,r),v <- cc_vs; Term.size l >= Term.size r ] in
  let rdc = new Rewriter.reducibility_checker ccsym' in
  rdc#init None;
  let require_red st =
    let r = Logic.big_or s.context [ rl | rl <- rdc#reducible_rule st ] in
    Logic.require r
  in
  L.iter require_red ccr
;;

let c_red_size ctx ccr = A.take_time A.t_cred (c_red_size ctx ccr)

(* globals to create CPred constraints faster *)
let reducibility_checker = ref (new Rewriter.reducibility_checker []);;

let c_min_cps _ cc =
  let ccsymm = L.fold_left (fun ccs (l,r) -> (r,l) :: ccs) cc cc in
  let rs = [ rl | rl <- ccsymm; Rule.is_rule rl ] in
  let c2 = [ !! (C.find_rule rl <&> (C.find_rule rl'))
             | rl <- rs; rl' <- rs; st <- O.nontrivial_cps rl rl' ] in
  L.iter (fun c -> Logic.assert_weighted c 1) c2;
;;

let check_equiv ctx a b =
  Logic.push ctx;
  Logic.require (!! (Logic.(<<=>>) a b));
  assert (not (Logic.check ctx));
  Logic.pop ctx
;;

let c_max_red_pre s cc ccsym_vs =
  let update_rdcbl_constr st rdc =
    let constr =
      try let c = Hashtbl.find C.ht_rdcbl_constr st in c <|> rlred s rdc st
      with Not_found -> rlred s rdc st
    in
    Hashtbl.replace C.ht_rdcbl_constr st constr;
    ignore (C.get_rdcbl_var s.context st)
  in
  (* build reducibility checkers, one for all and one for new nodes only*)
  let cc_new = [Lit.terms n | n <- s.new_nodes] in
  let cc_vs_new = [e, C.find_rule e | e <- cc_new @ [ r,l | l,r <- cc_new]] in
  let rdc_new = new Rewriter.reducibility_checker cc_vs_new in
  rdc_new#init None;
  let rdc_all = new Rewriter.reducibility_checker ccsym_vs in
  rdc_all#init (Some !reducibility_checker);
  let cc_old = [n | n <- cc; not (List.mem n cc_new)] in
  L.iter (fun st -> update_rdcbl_constr st rdc_all) cc_new;
  L.iter (fun st -> update_rdcbl_constr st rdc_new) cc_old
;;

let c_max_red_pre s = A.take_time A.t_cred (c_max_red_pre s)

let c_max_red s ccl =
  let reducible st =
    let c =
      try Hashtbl.find C.ht_rdcbl_constr st
      with _ -> failwith "Ckb.c_max_red: no constraint found"
    in
    let x_st = C.get_rdcbl_var s.context st in
    Logic.require (x_st <=>> c);
    if !(A.shape) = Boro || !(A.shape) = Ossigeno then (
      Logic.assert_weighted x_st 30;
      Logic.assert_weighted (C.find_rule st) 6)
    else
      Logic.assert_weighted x_st 6;
  in
  (* FIXME if C.ht_rdcbl_constr not used otherwise, iterate over it instead *)
  L.iter reducible ccl
;;

let c_max_red s = A.take_time A.t_cred (c_max_red s)

let c_cpred_pre s ccl cc_vs =
  let ovl_all = new Overlapper.overlapper_with cc_vs in
  ovl_all#init ();
  let rsn = [ Lit.terms n | n <- s.new_nodes ] in
  let cc_new_vs = [ rl, C.find_rule rl | rl <- rsn @ [ r,l | l,r <- rsn ] ] in
  let ovl_new = new Overlapper.overlapper_with cc_new_vs in
  ovl_new#init ();
  let rdc = new Rewriter.reducibility_checker cc_vs in
  rdc#init (Some !reducibility_checker);
  let is_reducible uv =
    try Hashtbl.find C.ht_rdcbl_constr uv
    with Not_found ->
      let c = rlred s rdc uv in
      Hashtbl.add C.ht_rdcbl_constr uv c;
      c
  in
  let overlaps_with ovl cc2 =
    let update_cp_reducible_constr (rl, rl_var) =
      let cp_red (uv, rl_var') = rl_var <&> rl_var' <=>> (is_reducible uv) in
      List.iter (fun ovl -> Logic.assert_weighted (cp_red ovl) 1) (ovl#cps rl)
    in
    List.iter update_cp_reducible_constr cc2
  in
  overlaps_with ovl_all cc_new_vs;
  (*FIXME latter be better cc_old*)
  if !A.iterations > 1 then overlaps_with ovl_new cc_vs
;;

let c_cpred_pre s ccl = A.take_time A.t_ccpred (c_cpred_pre s ccl)

let c_max_goal_red s cc ccsym_vs gs =
  let ccsym_vs = [(l,r),v | (l,r),v <- ccsym_vs; Term.size l >= Term.size r] in
  let rdc = new Rewriter.reducibility_checker ccsym_vs in
  rdc#init None;
  NS.iter (fun g -> Logic.assert_weighted (rlred s rdc (Lit.terms g)) 1) gs
;;

let c_comp s ns =
  let ctx = s.context in
 let rule_var, weight_var = C.find_rule, C.find_eq_weight in
 let all_eqs ee = Logic.big_and ctx (L.map C.find_eq ee) in
 (* induce order: decrease from e to equations in ee *)
 let dec e ee = Logic.big_and ctx [ weight_var e <>> weight_var f | f <- ee] in
 (* encode reducibility of equation st *)
 let red st =
  let es = try Hashtbl.find rewrite_trace st with Not_found -> [] in
  Logic.big_or ctx [ C.find_eq e <&> all_eqs ee <&> dec e ee | (ee,e) <- es ] 
 in
 let considered ((s,t) as st) =
   let c = Logic.big_or1 [rule_var st; rule_var (t,s); red st] in
   Logic.require (C.find_eq st <=>> c);
 in
 (* initial equations have to be considered *)
 let axs = !settings.axioms in
 Logic.require (all_eqs [Lit.terms l | l <- axs; Lit.is_equality l]);
 L.iter considered [ l,r | l,r <- ns; not (l=r) ];
;;

let c_comp s = A.take_time A.t_ccomp (c_comp s)

(* constraints to guide search; those get all retracted.
   ccl is list of all current literals in CC (nonsymmetric)
   ccsymlvs is list of (st, x_st) such that st is in symmetric closure of CC
*)
let search_constraints s (ccl, ccsymlvs) gs =
 (* orientable equations are used for CPs in CeTA ... *)
 let take_max = nth_iteration !heuristic.max_oriented in
 (* A.little_progress 5 && !A.equalities < 500 *)
 let assert_c = function
   | S.Red -> c_red s ccl ccsymlvs
   | S.Empty -> ()
   | S.Comp -> c_comp s ccl
   | S.RedSize -> c_red_size s ccl ccsymlvs
 in L.iter assert_c (constraints ());
 let assert_mc = function
   | S.Oriented -> c_maxcomp s ccsymlvs
   | S.NotOriented -> c_not_oriented s ccl
   | S.MaxRed -> c_max_red s ccl
   | S.MinCPs -> c_min_cps s ccl
   | S.GoalRed -> c_max_goal_red s ccl ccsymlvs gs
   | S.CPsRed
   | S.MaxEmpty -> ()
 in L.iter assert_mc (if take_max then [S.Oriented] else max_constraints ())
;;

(* find k maximal TRSs *)
let max_k s =
  let ctx, cc, gs = s.context, s.equations, s.goals in
  let k = (*if !A.iterations > 20 && !A.iterations mod 2 = 0 then 1 else*) !heuristic.k !(A.iterations) in
  let cc_eq = [ Lit.terms n | n <- NS.to_list cc ] in
  let cc_symm = [n | n <- NS.to_list (NS.symmetric cc)] in 
  let cc_symml = [Lit.terms c | c <- cc_symm] in
  L.iter (fun n -> ignore (C.store_rule_var ctx n)) cc_symml;
  (* lookup is not for free: get these variables only once *)
  let is_rule n = Rule.is_rule (Lit.terms n) in
  let cc_symm_vars = [n, C.find_rule (Lit.terms n) | n <- cc_symm; is_rule n] in
  let cc_symml_vars = [Lit.terms n,v | n,v <- cc_symm_vars] in
  if debug 2 then F.printf "K = %i\n%!" k;
  let strat = termination_strategy () in
  let no_dps = not (dps_used ()) in
  let rec max_k acc ctx n =
    if n = 0 then L.rev acc (* return TRSs in sequence of generation *)
    else (
      let sat_call = if use_maxsat () then Logic.max_sat else Logic.check in
      A.smt_checks := !A.smt_checks + 1;
      if A.take_time A.t_sat sat_call ctx then (
        let m = Logic.get_model ctx in
        let c = if use_maxsat () then Logic.get_cost ctx m else 0 in

        let add_rule (n,v) rls =
          if Logic.eval m v && (no_dps || not (Rule.is_dp (Lit.terms n))) then
            (n,v) :: rls
          else rls
        in
        let rr = L.fold_right add_rule cc_symm_vars []  in
        let order =
          if !settings.unfailing then St.decode 0 m strat
          else Order.default
        in
        if !S.generate_order then order#print_params ();
        if debug 2 then order#print ();
        if !settings.unfailing && !Settings.do_assertions then (
          let ord n =
            let l, r = Lit.terms n in order#gt l r && not (order#gt r l)
          in
          assert (L.for_all ord (L.map fst rr)));
        Logic.require (!! (Logic.big_and ctx [ v | _,v <- rr ]));
        max_k ((L.map fst rr, c, order) :: acc) ctx (n-1))
     else (
       if (n = k && L.length !heuristic.strategy > 1) then (
         if debug 2 then F.printf "restart (no further TRS found)\n%!";
         raise (Restart (Select.select_for_restart cc, false)));
       acc))
   in
   if has_comp () then
     NS.iter (fun n -> ignore (C.store_eq_var ctx (Lit.terms n))) cc;
   (* FIXME: restrict to actual rules?! *)
   A.take_time A.t_orient_constr (St.assert_constraints strat 0 ctx) cc_symml;
   c_max_red_pre s cc_eq cc_symml_vars;
   if has_cpred () then c_cpred_pre s cc_eq cc_symml_vars;
   Logic.push ctx; (* backtrack point for Yices *)
   Logic.require (St.bootstrap_constraints 0 ctx cc_symml_vars);
   search_constraints s (cc_eq, cc_symml_vars) gs;
   if !(Settings.generate_benchmarks) && A.runtime () > 100. then (
     let rs,is = !(A.restarts), !(A.iterations) in
     Smtlib.benchmark (string_of_int rs ^ "_" ^ (string_of_int is)));
   let trss = max_k [] ctx k in
   Logic.pop ctx; (* backtrack: get rid of all assertions added since push *)
   trss
;;

let new_oriented_by s o =
  let add_new rr l =
    let s, t = Lit.terms l in
    if o#gt s t then l :: rr else if o#gt t s then Lit.flip l :: rr else rr
  in 
  List.fold_left add_new [] s.new_nodes
;;

let max_k = A.take_time A.t_maxk max_k

(* some logging functions *)
let log_max_trs j rr rr' c =
  F.printf "TRS %i - %i (cost %i):\n %a\nreduced:%!\n %a\n@."
    !A.iterations j c
    Rules.print (Variant.rename_rules rr)
    Rules.print (Variant.rename_rules rr')
;;

let limit_reached t =
  match strategy_limit () with
    | IterationLimit i when !(A.iterations) > i -> true
    | TimeLimit l when t > l -> true
    | _ -> false
;;

(* towards main control loop *)
(* Heuristic to determine whether the state is stuck in that no progress was
   made in the last n iterations. *)
let do_restart s =
if A.memory () > 6000 then (
  if debug 1 then F.printf "restart (memory limit of 6GB reached)\n%!";
  true)
else
  (* no progress measure *)
  let es, gs = s.equations, s.goals in
  let h = Hashtbl.hash (NS.size es, es, gs) in
  let rep = L.for_all ((=) h) !hash_iteration in
  hash_iteration := h :: !hash_iteration;
  hash_iteration := Listx.take_at_most 20 !hash_iteration;
  if rep && debug 1 then F.printf "restart (repeated iteration state)\n%!";
  (* iteration/size bound*)
  (* estimate exponential blowup *)
  let blow n m = float_of_int n >= 1.5 *. (float_of_int m) in
  let rec is_exp = function n::m::cs -> blow n m && is_exp (m::cs) | _ -> true in
  let eqcounts = Listx.take_at_most 6 !(A.eq_counts) in
  let blowup = !(A.iterations) > 6 && is_exp eqcounts in
  if blowup && debug 1 then F.printf "restart (blowup)\n%!";
  if limit_reached (A.runtime ()) && debug 1 then
    F.printf "restart (limit reached)\n%!";
  rep || limit_reached (A.runtime ()) || blowup
;;

let check_hard_restart s =
  if Unix.gettimeofday () -. !A.hard_restart_time > !time_limit then (
    match !heuristics with
    | (h, t, name) :: hs ->
      if debug 1 then
        Format.printf "hard restart %.2f: next %s\n%!" ( Unix.gettimeofday () -. !A.hard_restart_time) name;
      set_heuristic h;
      time_limit := t;
      heuristics := hs;
      A.hard_restart ();
      raise (Restart ([], true))
    | _ -> failwith "no further heuristic found"
  )
;;

let detect_shape es =
  let shape = A.problem_shape es in
  A.shape := shape;
  if debug 1 then
    F.printf "detected shape %s\n%!" (Settings.shape_to_string shape);
  let emax k = L.fold_left max k [ Lit.size l  | l <- !settings.axioms] in
  let gmax k = L.fold_left max k [ Rule.size l  | l <- !settings.gs] in
  let h = !heuristic in
  let hs =
    match shape with
    | Piombo -> [h_piombo h, 1000.,"piombo"]
    | Zolfo -> [h_zolfo0 h,80.,"z0"; h_zolfo h,90.,"z"; h_boro h,1000.,"boro"]
    | Xeno -> [h_xeno h, 120.,"xeno"; h_piombo h, 60.,"piombo"; (* REL024-1: 20s fullCPwithAx*)
               h_carbonio0 h, 1000.,"carbonio0" ]
    | Anello -> [h_anello h, 1000.,"anello"]
    | Elio -> [h_elio0 h, 30.,"elio0"; h_elio h, 100.,"elio";
               h_piombo h, 1000.,"piombo"]
    | Silicio -> [h_silicio h, 1000.,"silicio"]
    | Ossigeno -> [ h_boro h, 30.,"boro"; h_piombo h, 40.,"piombo";
                    h_ossigeno h, 1000.,"ossigeno"]
    | Carbonio -> [h_carbonio1 h, 4.,"carb1"; h_carbonio0 h, 1000.,"carb0"]
    | Magnesio -> [h_magnesio h, 1000.,"magnesio"]
    | NoShape -> [h_no_shape0 h, 90.,"shapeless"; h_carbonio0 h, 30.,"carb0";
                  h_no_shape1 h, 1000.,"shapeless1"]
    | Idrogeno -> [h_idrogeno h, 1000.,"idrogeno"]
    | Boro -> [h_boro h, 1000.,"boro"]
  in
  let fix_bounds (h, l, n) = ({ h with
    soft_bound_equations = emax h.soft_bound_equations;
    soft_bound_goals = gmax h.soft_bound_goals;
    }, l, n)
  in
  match List.map fix_bounds hs with
  | (h0, t, _) :: hs' -> (
    set_heuristic h0;
    time_limit := t;
    heuristics := hs')
  | _ -> failwith "no heuristic found"
;;


let set_iteration_stats s =
  let aa, gs = s.equations, s.goals in
  let i = !A.iterations in
  A.iterations := i + 1;
  A.equalities := NS.size aa;
  A.goals := NS.size gs;
  A.set_time_mem ();
  A.eq_counts := NS.size aa :: !(A.eq_counts);
  A.goal_counts := NS.size gs :: !(A.goal_counts);
  if debug 1 then (
    if debug 2 then 
   F.printf "Start iteration %i with %i equations:\n %a\n%!"
     !A.iterations (NS.size aa) NS.print aa;
   if !A.goals > 0 then
     let gnd = Rules.is_ground [ Lit.terms g | g <- NS.to_list gs ] in
     F.printf "\nand %i goals:\n%a %i%!\n" !A.goals NS.print gs
       (if gnd then 1 else 0));
  if debug 3 then (
    A.print ();
    A.show_proof_track !settings Select.all_nodes);
  (* re-evaluate symbols status not every iteration, too expensive *)
  if i mod 2 = 0 then (
    let rs = [Lit.terms e | e <- NS.to_list aa] in
    let cs = Commutativity.symbols rs in
    let acs = Ac.symbols rs in
    if debug 1 && (acs <> !settings.ac_syms || cs <> !settings.only_c_syms) then
      Format.printf "discovered %s symbols\n%!"
        (if acs <> !settings.ac_syms then "AC" else "C");
    let s = {!settings with ac_syms = acs; only_c_syms = cs} in
    set_settings s)
;;

let store_trs ctx j rr cost =
  let rr = [ Lit.terms r | r <- rr ] in
  let rr_index = C.store_trs rr in
  (* for rewriting actually reduced TRS may be used; have to store *)
  let rr_reduced =
    if not !heuristic.reduce_trss then rr
    else if !(Settings.do_proof) <> None then interreduce rr
    else Variant.reduce_encomp rr
  in
  (*let subset rr' = Listset.subset rr_reduced rr' in
  let tt = Unix.gettimeofday () in
  let repeated = List.exists subset !last_trss in 
  A.t_tmp2 := !A.t_tmp2 +. (Unix.gettimeofday () -. tt);
  (*if repeated then Format.printf "repeated TRS %d\n%!" j;*)
  last_trss := rr_reduced :: !last_trss;*)
  C.store_redtrs rr_reduced rr_index;
  C.store_rule_vars ctx rr_reduced; (* otherwise problems in norm *)
  if has_comp () then C.store_eq_vars ctx rr_reduced;
  if debug 2 then log_max_trs j rr rr_reduced cost;
  rr_index
;;

let check_order_generation success order =
  if !S.generate_order &&
      (success || limit_reached (A.runtime ()) || A.runtime () > 30.) then (
    order#print_params ();
    exit 0)
;;

let last_rewriters = ref []

let get_rewriter ctx j (rr, c, order) =
  let n = store_trs ctx j rr c in
  let rr_red = C.redtrs_of_index n in (* interreduce *)
  let rew = new Rewriter.rewriter !heuristic rr_red !settings.ac_syms order in
  check_order_generation false order;
  rew#init ();
  last_rewriters := (if j = 0 then [rew] else !last_rewriters @ [rew]);
  rew
;;

let extend_theory s phi =
  match s.extension with
  | None -> failwith "Ckb.extend_theory"
  | Some sext -> 
    let ext_list = sext.theory_extensions in 
    if debug 2 then Format.printf "extend level %d\n%!" (List.length ext_list);
    let exs, ex_rest = List.hd ext_list, List.tl ext_list in
    let sext' = {theory_extensions = ex_rest; iterations = 0} in
    let s = {s with extension = Some sext'} in
    let rec extend = function
    | [] -> raise Backtrack
    | r :: rs ->
      let s' = copy_state s in
      let s' = {s' with equations = NS.add_list r s'.equations} in
      if debug 2 && L.length r = 1 then
        Format.printf " extend %a\nbase is%a \n%!%!"
          Lit.print (List.hd r) NS.print s'.equations;
      try phi s'
      with Backtrack -> extend rs
    in
    try extend exs with Backtrack -> raise (Restart ([], false))
;;

let is_extension_iteration i s =
  match s.extension with
  | None -> false
  | Some sx -> sx.iterations = i
;;

let may_extend s =
  match s.extension with
  | None -> false
  | Some sx -> sx.theory_extensions <> []
;;

let inconsistent ee=
  let ee = [Lit.terms e | e <- NS.to_list ee] in
  L.exists (function (T.V x,T.V y) -> x<>y | _ -> false) ee
;;

let filter_cps bound cps0 =
  let t = Unix.gettimeofday () in
  let rec filter b cps = 
    let cps' = [ l, s | l, s <- cps; s < b] in
    if List.length cps' > 4000 then filter (b - 2) cps'
    else
      let cps_large =
        if NS.size cps0 > 4000 then None
        else Some (NS.filter (fun cp -> Lit.size cp >= b) cps0)
      in
      NS.of_list [l | l, _ <- cps'], cps_large, b
  in
  let cps_s, cps_l, b = filter bound [l, Lit.size l | l <- NS.to_list cps0] in
  (*Format.printf "filter out %d, %d remaining, bound %d\n%!"
    (match cps_l with Some s -> NS.size s | _ -> -1) (NS.size cps_s) b;*)
  A.t_tmp3 := !A.t_tmp3 +. (Unix.gettimeofday () -. t);
  cps_s, cps_l
;;

let filter_cps state bound cps0 =
  let t = Unix.gettimeofday () in
  let the_limit = !heuristic.cp_cutoff in 
  let rec filter b cps = 
    let cps' = [ l, s | l, s <- cps; s < b] in
    if List.length cps' > the_limit then filter (b - 2) cps'
    else
      let cps_large =
        if NS.size cps0 > 4000 then None
        else Some (NS.filter (fun cp -> Lit.size cp >= b) cps0)
      in
      NS.of_list [l | l, _ <- cps'], cps_large, b
  in
  let cps = NS.filter (fun cp -> Lit.size cp < bound) cps0 in
  let cps_large = NS.filter (fun cp -> Lit.size cp >= bound) cps0 in
  let cps_s, cps_l, b = 
    if NS.size cps < the_limit then cps, Some cps_large, bound (* like before *)
    else filter (bound - 2) [l, Lit.size l | l <- NS.to_list cps0]
  in
  (*Format.printf "filter out %d, %d remaining, bound %d\n%!"
    (match cps_l with Some s -> NS.size s | _ -> -1) (NS.size cps_s) b;*)
  A.t_tmp3 := !A.t_tmp3 +. (Unix.gettimeofday () -. t);
  cps_s, cps_l
;;

let rec phi s =
  if do_restart s then
    raise (Restart (Select.select_for_restart s.equations, false));
  check_hard_restart s;
  let redcount, cp_count = ref 0, ref 0 in
  set_iteration_stats s;
  Select.reset ();
  let aa, gs = s.equations, s.goals in
  (**)
  if debug 2 then (Format.printf "iteration %d %!" !A.iterations;
  Format.printf "(%s)\n%!" (match !heuristic.mode with
  | OnlySAT -> "only sat" | OnlyUNSAT -> "only unsat" | _ -> "both"));
  let s = if not (unsat_allowed ()) && s.extension = None && !A.restarts = 0 && !A.iterations <= 1 then
    set_extension s else s in 
  let s = {s with extension = (match s.extension with
    | None -> None
    | Some sx -> Some {sx with iterations = sx.iterations + 1})} in 
  if is_extension_iteration 3 s then
    (if may_extend s then extend_theory s phi else (
      if debug 2 then Format.printf "backtrack as unextensible\n%!"; raise Backtrack))
  else
  (**)
  let process (j, s, aa_new) ((rr, c, order) as sys) =
    let aa, gs = s.equations, s.goals in
    let rew = get_rewriter s.context j sys in
    let irred, red = if !A.shape = Silicio && j > 1 then NS.empty (), NS.empty () else rewrite rew aa in (* rewrite eqs wrt new TRS *)
    redcount := !redcount + (NS.size red);

    let gs_red', gs_big = if !A.shape = Silicio && j > 1 then NS.empty (), NS.empty () else reduced_goals rew gs in
    let gs = NS.add_all gs_red' gs in

    let aa_for_ols = equations_for_overlaps red irred aa in
    let cps', ovl = overlaps ~only_new:true s rr aa_for_ols in
    cp_count := !cp_count +  (NS.size cps');
    (*let eq_bound = !heuristic.hard_bound_equations in
    let cps = NS.filter (fun cp -> Lit.size cp < eq_bound) cps' in
    let cps_large = NS.filter (fun cp -> Lit.size cp >= eq_bound) cps' in*)
    let cps, cps_large = filter_cps s !heuristic.hard_bound_equations cps' in
    let t = Unix.gettimeofday () in
    let cps = reduced ~normalize:true rew cps in
    A.t_tmp2 := !A.t_tmp2 +. (Unix.gettimeofday () -. t);
    let nn = NS.diff (NS.add_all cps red) aa in (* new equations *)
    let sel, rest = Select.select (aa,rew) nn in

    let go = overlaps_on rr aa_for_ols gs in
    let gcps, gcps' = reduced_goal_cps rew go in
    let gs' = NS.diff (NS.add_all gs_big (NS.add_all gcps' gcps)) gs in
    let gg, grest = Select.select_goals (aa,rew) !heuristic.n_goals gs' in

    if !(Settings.track_equations) <> [] then
      A.update_proof_track (sel @ gg) (NS.to_list rest @ (NS.to_list grest));
    store_remaining_nodes s.context rest grest;
    let ieqs = NS.to_rules (NS.filter Lit.is_inequality aa) in
    let cc = (!settings.axioms, cps, cps_large) in
    let irr = NS.filter Lit.not_increasing (NS.symmetric irred) in

    if not (unsat_allowed ()) && inconsistent irr && not (NS.is_empty gs) then
      (if debug 2 then Format.printf "inconsistent branch\n%!";
        raise (if s.extension <> None then Backtrack else Fail));
    let gs' = NS.add_list gg gs in
    match succeeds s (rr, irr) rew cc ieqs gs' with
       Some r ->
       if !(Settings.generate_benchmarks) then
         Smtlib.benchmark "final";
       if !S.generate_order then
         (check_order_generation true order; failwith "order generated")
       else raise (Success r)
     | None ->
       let s' = update_state s (NS.add_list sel aa) gs' in
       (j+1, s', sel @ aa_new)
  in
  try
    let s = update_state s aa gs in
    let rrs = max_k s in
    let _, s', aa_new = L.fold_left process (0, s, []) rrs in
    let sz = match rrs with (trs,c,_) :: _ -> List.length trs,c | _ -> 0,0 in
    let cp_count = if rrs = [] then 0 else !cp_count / (List.length rrs) in
    A.add_state !redcount (fst sz) (snd sz) cp_count;
    phi {s' with new_nodes = aa_new; last_trss = rrs}
  with Success r -> r
  | Backtrack -> raise (Restart ([], false))
;;

let init_settings (settings_flags, heuristic_flags) axs (gs : Lit.t list) =
  A.restart ();
  A.iterations := 0;
  let axs_eqs = [ Lit.terms a | a <- axs ] in
  let acs = Ac.symbols axs_eqs in
  let cs = Commutativity.symbols axs_eqs in
  let is_large = L.length axs_eqs >= 90 &&
    L.length (L.filter Rule.is_ground axs_eqs) > 45 (* AQL systems *) in
  let gs_eqs = [Lit.terms g | g <- gs] in
  let s =
    { !settings with
      ac_syms = acs;
      auto = if is_large then false else settings_flags.auto;
      axioms = axs;
      debug = settings_flags.debug;
      gs = gs_eqs;
      only_c_syms = Listset.diff cs acs;
      signature = Rules.signature (axs_eqs @ gs_eqs);
      tmp = settings_flags.tmp;
      unfailing = settings_flags.unfailing
    }
  in
  let s = if !heuristic.fix_parameters then fix_group_params s else s in
  let h =
    if is_large then (
      let saql = St.strategy_aql in
      { !heuristic with k = (fun _ -> 6); reduce_trss = false; strategy = saql })
    else
      { !heuristic with
        n = heuristic_flags.n;
      }
  in
  set_settings s;
  set_heuristic h;
  if !A.hard_restarts = 0 && settings_flags.auto && not is_large then
    detect_shape axs_eqs;
  if !(Settings.do_proof) = Some CPF then (
    Tr.add_initials axs_eqs;
    Tr.add_initial_goal gs_eqs)
  else if !(Settings.do_proof) = Some TPTP then
    Lit.LightTrace.add_initials (gs @ axs);
  if !heuristic.reduce_AC_equations_for_CPs then (
    let acx = [ Lit.make_axiom (normalize (Ac.cassociativity f)) | f <- acs ] in
    acx_rules := [ Lit.flip r | r <- acx ] @ acx);
  A.init_proof_track !(Settings.track_equations);
  A.update_proof_track axs [];
;;

let remember_state es gs =
 let h = Hashtbl.hash (termination_strategy (), es, gs) in
 if h = !hash_initial then
   set_heuristic {!heuristic with n = (fun _ -> max (!heuristic.n 0 + 1) 15)};
 hash_initial := h
;;

let pre_check (es, gs) =
  let fs = List.map fst (Rules.signature (List.map Lit.terms es)) in
  let rec disj_funs = function
  | []
  | (Term.V _, _) :: _
  | (_, Term.V _) :: _ -> false
  | (Term.F(f, ss), Term.F(g, ts)) :: gs ->
    if f = g && Signature.get_fun_name f = "_goal" then
      disj_funs (Listx.zip ss ts)
    else
      if not (List.mem f fs) && not (List.mem g fs) && f <> g then true
      else disj_funs gs
  in
  let disj_funs = match gs with g :: gs -> disj_funs [Lit.terms g] | _ -> false in
  disj_funs
;;

let preorient s es =
  let es = [ Variant.normalize_rule_dir (Lit.terms e) | e <- es ] in
  let es' = [ if d then e else R.flip e | e,d <- es ] in
  let oriented = [ C.rule_var s.context r | r <- es' ] in
  let keep = Logic.big_and s.context oriented in
  Logic.require keep
;;

let ext (es,gs) settings =
  if L.length gs != 1 || Lit.is_ground (List.hd gs) then (es,gs), settings
  else
    let s,t = Lit.terms (List.hd gs) in
    let eq = Sig.fun_called "_equals" in
    let tr = Sig.fun_called "_true" in
    let fa = Sig.fun_called "_false" in
    let x = Sig.var_called "x" in
    let l1 = Lit.make_axiom (T.F(eq,[T.V x; T.V x]), T.F(tr,[])) in
    let l2 = Lit.make_axiom (T.F(eq,[s; t]), T.F(fa,[])) in
    let es' = l1 :: l2 :: es in
    let gs' = [Lit.make_neg_axiom (T.F(fa,[]), T.F(tr,[]))] in
    let s = {settings with axioms = es'; gs = L.map Lit.terms gs'} in
    (es', gs'), s
;;

let ckb ((settings_flags, heuristic_flags) as flags) input =
  (*let input,settings_flags =
    if !(S.do_proof) <> None then ext input settings_flags
    else input, settings_flags
  in*)
  set_settings settings_flags;
  set_heuristic heuristic_flags;
  if debug 2 then Format.printf "strategy %s\n%!" (Strategy.to_string heuristic_flags.strategy);
  A.hard_restart_time := Unix.gettimeofday ();
  
  let eq_ok e = Lit.is_equality e || Lit.is_ground e in
  if not (L.for_all eq_ok (fst input)) then
    raise Fail;
  remember_state (fst input) (snd input);
  let rec ckb (es, gs) =
    let est =
      if !(S.do_proof) <> None then [e | e <- es;not (Lit.is_trivial e)] else es
    in
    let es' = L.map Lit.normalize est in
    let es0 = L.sort Stdlib.compare es' in
    let gs0 = L.map Lit.normalize gs in
    Select.init es0 gs0;
    init_settings flags es0 gs0;
    if debug 2 then Format.printf "strategy %s\n%!" (Strategy.to_string !heuristic.strategy);
    try
      let cas = [ Ac.cassociativity f | f <- !settings.ac_syms ] in
      if !(S.do_proof) <> None then
        trace_cassociativity !settings.ac_syms;
      let es0 = [ Lit.make_axiom (normalize r) | r <- cas ] @ es0 in
      let ctx = Logic.mk_context () in
      let ss = Listx.unique (t_strategies ()) in
      L.iter (fun s -> St.init !settings s 0 ctx) ss;
      let state = make_state ctx (!settings.norm @ es0) (NS.of_list gs0) in
      if !settings.keep_orientation then
        preorient state es;
      if !settings.norm <> [] then
        preorient state !settings.norm;
      let start = Unix.gettimeofday () in
      let res = phi state in
      A.t_process := !(A.t_process) +. (Unix.gettimeofday () -. start);
      Logic.del_context ctx;
      res
    with Restart (es_new, is_hard) -> (
      if debug 1 then
        Format.printf "New lemmas on restart:\n%a\n%!" NS.print_list es_new;
      if is_hard then (
        Tr.clear ();
        Lit.LightTrace.clear ();
        Lit.last_id := 0
      ) else pop_strategy ();
      St.clear ();
      Cache.clear ();
      A.restarts := !A.restarts + 1;
      Hashtbl.reset rewrite_trace;
      NS.reset_age ();
      A.mem_diffs := [];
      A.time_diffs := [];
      Select.all_nodes := [];
      Select.all_goals := [];
      Select.min_all_nodes := max_int;
      Select.min_all_goals := max_int;
      NS.H.reset goal_cp_table;
      let es' = if gs = [] || not (unsat_allowed ()) then [] else es_new in
      let esx = List.map Lit.terms (es' @ es0) in
      let shape = A.problem_shape esx in
      if !settings.auto && shape <> !A.shape && shape <> NoShape then
        detect_shape esx;
      heuristic := {!heuristic with mode = SATorUNSAT};
      let es,gs = if is_hard &&
        not ( !A.shape = Xeno && !heuristic.hard_bound_equations > 3000) &&
        !A.shape <> Zolfo then input else es, gs in
      ckb (es' @ es, gs))
  in
  ckb input
;;

let ckb ((settings_flags, heuristic_flags) as flags) ((es,gs) as input) =
  let fs = Rules.signature (List.map Lit.terms es) in
  if pre_check input && settings_flags.infeasible then (
    (*Format.printf "suspicious %d\n%!" (List.length [f | f,a <- fs; a = 1]);*)
    try
      let u = List.hd [f | f,a <- fs; a = 1] in
      let es' = Lit.make_axiom (T.F(u, [T.V 0]), T.F(1001, [])) :: es in
      match ckb flags (es', gs) with
      | (UNSAT, _) -> ckb flags input
      | (SAT, r) -> (SAT,r)
    with _ -> ckb flags input
  ) else
    ckb flags input
;;

