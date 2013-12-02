(* -------------------------------------------------------------------- *)
open EcUid
open EcUtils
open EcMaps
open EcIdent
open EcLocation
open EcSymbols
open EcParsetree
open EcTypes
open EcModules
open EcFol

open EcMetaProg
open EcBaseLogic
open EcEnv
open EcLogic
open EcCoreHiLogic

module Sp = EcPath.Sp

module TT = EcTyping
module UE = EcUnify.UniEnv

(* -------------------------------------------------------------------- *)
type hitenv = {
  hte_provers : EcParsetree.pprover_infos -> EcProvers.prover_infos;
  hte_smtmode : [`Admit | `Strict | `Standard];
}

type engine = ptactic_core -> tactic

(* -------------------------------------------------------------------- *)
type tac_error =
  | UnknownHypSymbol of symbol
  | UnknownAxiom     of qsymbol
  | UnknownOperator  of qsymbol
  | BadTyinstance
  | NothingToIntro
  | FormulaExpected
  | MemoryExpected
  | UnderscoreExpected
  | ModuleExpected
  | ElimDoNotWhatToDo
  | NoCurrentGoal

exception TacError of tac_error

let pp_tac_error fmt =
  function
    | UnknownHypSymbol s ->
      Format.fprintf fmt "Unknown hypothesis or logical variable %s" s
    | UnknownAxiom qs ->
      Format.fprintf fmt "Unknown axioms or hypothesis : %a"
        pp_qsymbol qs
    | UnknownOperator qs ->
      Format.fprintf fmt "Unknown operator or logical variable %a"
        pp_qsymbol qs
    | BadTyinstance ->
      Format.fprintf fmt "Invalid type instance"
    | NothingToIntro ->
      Format.fprintf fmt "Nothing to introduce"
    | FormulaExpected ->
      Format.fprintf fmt "formula expected"
    | MemoryExpected ->
      Format.fprintf fmt "Memory expected"
    | UnderscoreExpected ->
      Format.fprintf fmt "_ expected"
    | ModuleExpected ->
      Format.fprintf fmt "module expected"
    | ElimDoNotWhatToDo ->
      Format.fprintf fmt "Elim : do not known what to do"
    | NoCurrentGoal ->
      Format.fprintf fmt "No current goal"

let _ = EcPException.register (fun fmt exn ->
  match exn with
  | TacError e -> pp_tac_error fmt e
  | _ -> raise exn)

let error loc e = EcLocation.locate_error loc (TacError e)

(* -------------------------------------------------------------------- *)
let process_trivial = EcPhlTrivial.t_trivial

(* -------------------------------------------------------------------- *)
let process_done g =
  match process_trivial g with
  | (_, []) as g -> g
  | _ -> tacuerror "[by]: cannot close goals"

(* -------------------------------------------------------------------- *)
let process_congr g =
  let (hyps, concl) = get_goal g in

  if not (EcFol.is_eq concl) then
    tacuerror "congr: goal must be an equality";

  let (f1, f2) = EcFol.destr_eq concl in

  match f1.f_node, f2.f_node with
  | Fapp (o1, a1), Fapp (o2, a2)
      when    EcReduction.is_alpha_eq hyps o1 o2
           && List.length a1 = List.length a2 ->
    t_congr o1 ((List.combine a1 a2), f1.f_ty) g

  | _, _ when EcReduction.is_alpha_eq hyps f1 f2 ->
    t_congr f1 ([], f1.f_ty) g

  | _, _ -> tacuerror "congr: no congruence"

(* -------------------------------------------------------------------- *)
let process_instanciate hyps ({pl_desc = pq; pl_loc = loc} ,tvi) =
  let env = LDecl.toenv hyps in
  let (p, ax) =
    try EcEnv.Ax.lookup pq env
    with _ -> error loc (UnknownAxiom pq) in
  let args = process_tyargs hyps tvi in
  let args =
    (* FIXME: TC HOOK *)
    match List.map fst ax.EcDecl.ax_tparams, args with
    | [], None -> []
    | [], Some _ -> error loc BadTyinstance
    | ltv, Some (EcUnify.TVIunamed l) ->
        if not (List.length ltv = List.length l) then error loc BadTyinstance;
        l
    | ltv, Some (EcUnify.TVInamed l) ->
        let get id =
          try List.assoc (EcIdent.name id) l
          with _ -> error loc BadTyinstance
        in
          List.map get ltv
    | _, None -> error loc BadTyinstance in
  p,args

(* -------------------------------------------------------------------- *)
let process_global loc tvi g =
  let hyps = get_hyps g in
  let p, tyargs = process_instanciate hyps tvi in
  set_loc loc t_glob p tyargs g

(* -------------------------------------------------------------------- *)
let process_assumption loc (pq, tvi) g =
  match pq with
  | None ->
      if (tvi <> None) then error loc BadTyinstance;
      t_assumption g
  | Some pq ->
    let hyps = get_hyps g in
      match unloc pq with
      | ([],ps) when LDecl.has_hyp ps hyps ->
          if (tvi <> None) then error pq.pl_loc BadTyinstance;
          set_loc loc (t_hyp (fst (LDecl.lookup_hyp ps hyps))) g
      | _ -> process_global loc (pq,tvi) g

(* -------------------------------------------------------------------- *)
let process_reflexivity loc g =
  set_loc loc EcLogic.t_reflex g

(* -------------------------------------------------------------------- *)
let process_dbhint env db =
  let add hints x =
    let nf kind p =
      let s = string_of_qsymbol (unloc p) in
        set_loc p.pl_loc
          (fun () -> tacuerror "cannot find %s `%s'" kind s)
          ()
    in
  
    let addm hints hflag p =
      match EcEnv.Theory.lookup_opt (unloc p) env with
      | None -> nf "theory" p
      | Some (p, _) -> EcProvers.Hints.addm p hflag hints
  
    and add1 hints hflag p =
      match EcEnv.Ax.lookup_opt (unloc p) env with
      | None -> nf "lemma" p
      | Some (p, _) -> EcProvers.Hints.add1 p hflag hints
    in
      match x.pht_kind with
      | `Theory -> addm hints x.pht_flag x.pht_name
      | `Lemma  -> add1 hints x.pht_flag x.pht_name

  in
    match db with
    | None    -> (true, EcProvers.Hints.full)
    | Some db ->
      let hints = EcProvers.Hints.full in
      let hints = List.fold_left add hints db.pht_map in
        (not db.pht_nolocals, hints)

let process_smt hitenv (db, pi) g =
  let env = LDecl.toenv (get_hyps g) in
  let db  = process_dbhint env db in
  let pi  = hitenv.hte_provers pi in

  match hitenv.hte_smtmode with
  | `Admit    -> t_admit g
  | `Standard -> t_seq (t_simplify_nodelta) (t_smt ~strict:false db pi) g
  | `Strict   -> t_seq (t_simplify_nodelta) (t_smt ~strict:true  db pi) g

(* -------------------------------------------------------------------- *)
let process_clear l g =
  let hyps = get_hyps g in
  let toid ps =
    let s = ps.pl_desc in
    if LDecl.has_symbol s hyps then (fst (LDecl.lookup s hyps))
    else error ps.pl_loc (UnknownHypSymbol s) in
  let ids = EcIdent.Sid.of_list (List.map toid l) in
  t_clear ids g

(* -------------------------------------------------------------------- *)
let process_simplify ri g =
  let env,hyps,_ = get_goal_e g in
  let delta_p, delta_h =
    match ri.pdelta with
    | None -> None, None
    | Some l ->
      let sop = ref Sp.empty and sid = ref EcIdent.Sid.empty in
      let do1 ps =
        match ps.pl_desc with
        | ([],s) when LDecl.has_symbol s hyps ->
          let id = fst (LDecl.lookup s hyps) in
          sid := EcIdent.Sid.add id !sid;
        | qs ->
          let p =
            try EcEnv.Op.lookup_path qs env
            with _ -> error ps.pl_loc (UnknownOperator qs) in
          sop := Sp.add p !sop in
      List.iter do1 l;
      Some !sop, Some !sid in
  let ri = {
    EcReduction.beta    = ri.pbeta;
    EcReduction.delta_p = delta_p;
    EcReduction.delta_h = delta_h;
    EcReduction.zeta    = ri.pzeta;
    EcReduction.iota    = ri.piota;
    EcReduction.logic   = ri.plogic; 
    EcReduction.modpath = ri.pmodpath;
  } in
  t_simplify ri g

(* -------------------------------------------------------------------- *)
let process_subst loc ri g =
  if ri = [] then t_subst_all g
  else
    let hyps = get_hyps g in
    let totac ps =
      let f = process_form_opt hyps ps None in
      try t_subst1 (Some f) 
      with _ -> assert false (* FIXME error message *) in
    let tacs = List.map totac ri in
    set_loc loc (t_lseq tacs) g

(* -------------------------------------------------------------------- *)
exception RwMatchFound of EcUnify.unienv * (uid -> ty option) * form evmap

let try_match hyps (ue, ev) p form =
  let na = List.length (snd (EcFol.destr_app p)) in

  let trymatch bds tp =
    let tp =
      match tp.f_node with
      | Fapp (h, hargs) when List.length hargs > na ->
          let (a1, a2) = List.take_n na hargs in
            f_app h a1 (toarrow (List.map f_ty a2) tp.f_ty)
      | _ -> tp
    in

    try
      if not (Mid.set_disjoint bds tp.f_fv) then
        None
      else
        let (ue, tue, ev) = f_match hyps (ue, ev) ~ptn:p tp in
          raise (RwMatchFound (ue, tue, ev))
    with MatchFailure -> None
  in

  try
    ignore (FPosition.select trymatch form); None
  with RwMatchFound (ue, tue, ev) -> Some (ue, tue, ev)

(* -------------------------------------------------------------------- *)
let process_apply loc pe g =
  let (hyps, fp) = (get_hyps g, get_concl g) in
  let (p, typs, ue, ax) = process_pterm loc (process_formula hyps) hyps pe in
  let args = List.map (trans_pterm_argument hyps ue) pe.fp_args in
  let (ax, ids) = check_pterm_arguments hyps ue ax args in

  let rec instanciate (ax, ids) =
    let ev = evmap_of_pterm_arguments ids in

    try  (ax, ids, EcMetaProg.f_match hyps (ue, ev) ax fp);
    with MatchFailure ->
      match destruct_product hyps ax with
      | None   -> tacuerror "in apply, cannot find instance"
      | Some _ ->
          let (ax, id) = check_pterm_argument hyps ue ax None in
            instanciate (ax, id :: ids)
  in

  let (_, ids, (_, tue, ev)) =
    let fully_instantiate =
      can_concretize_pterm_arguments (ue, EV.empty) ids
    in

      match fully_instantiate with
      | false -> instanciate (ax, ids)
      | true  ->
          let closedax = Fsubst.uni (EcUnify.UniEnv.close ue) ax in

          if EcReduction.is_conv hyps closedax fp then begin
            (ax, ids, (ue, EcUnify.UniEnv.close ue, EV.empty))
          end else
            instanciate (ax, ids)
  in

  let args = concretize_pterm_arguments (tue, ev) ids in
  let typs = List.map (Tuni.offun tue) typs in

    match p with
    | `Global p ->
        gen_t_apply_glob (fun _ _ x -> x) p typs args g

    | `Local x -> 
        assert (typs = []);
        gen_t_apply_hyp (fun _ _ x -> x) x args g

    | `Cut fc ->
        assert (typs = []);
        gen_t_apply_form (fun _ _ x -> x)
          (Fsubst.uni (EcUnify.UniEnv.close ue) fc) args g

(* -------------------------------------------------------------------- *)
let process_rewrite1_core (s, o) (p, typs, ue, ax) args g =
  let (hyps, concl) = get_goal g in
  let env = LDecl.toenv hyps in

  let ((_ax, ids), (_mode, (f1, f2))) =
    let rec find_rewrite_pattern (ax, ids) =
      match EcFol.sform_of_form ax with
      | EcFol.SFeq  (f1, f2) -> ((ax, ids), (`Eq, (f1, f2)))
      | EcFol.SFiff (f1, f2) -> ((ax, ids), (`Ev, (f1, f2)))
      | _ -> begin
        match destruct_product hyps ax with
        | None ->
            if s = `LtoR && EcReduction.EqTest.for_type env ax.f_ty tbool then
              ((ax, ids), (`Bool, (ax, f_true)))
            else
              tacuerror "not an equation to rewrite"
        | Some _ ->
            let (ax, id) = check_pterm_argument hyps ue ax None in
              find_rewrite_pattern (ax, id :: ids)
      end

    in
      find_rewrite_pattern (check_pterm_arguments hyps ue ax args)
  in

  let fp = match s with `LtoR -> f1 | `RtoL -> f2 in

  let (_ue, tue, ev) =
    let ev = evmap_of_pterm_arguments ids in

    match try_match hyps (ue, ev) fp concl with
    | None   -> tacuerror "cannot find an occurence for [rewrite]"
    | Some x -> x
  in

  let args = concretize_pterm_arguments (tue, ev) ids in
  let typs = List.map (Tuni.offun tue) typs in
  let fp   = concretize_pterm (tue, ev) ids fp in

  let cpos =
    try  FPosition.select_form hyps o fp concl
    with InvalidOccurence -> tacuerror "invalid occurence selector"
  in

  let fpat _ _ _ = FPosition.topattern cpos concl in

  match p with
  | `Global x ->
      t_rewrite_glob ~fpat s x typs args g

  | `Local x ->
      assert (typs = []);
      t_rewrite_hyp ~fpat s x args g

  | `Cut fc ->
      assert (typs = []);
      t_rewrite_form ~fpat s fc args g

(* -------------------------------------------------------------------- *)
let rec process_rewrite1 loc ri g =
  let (hyps, concl) = get_goal g in

  match ri with
  | RWDone b ->
      let t = if b then t_simplify_nodelta else (t_id None) in
        t_seq t process_trivial g

  | RWSimpl ->
      t_simplify_nodelta g

  | RWDelta (s, o, f) -> begin
      let env      = LDecl.toenv hyps in
      let (ps, ue) = (ref Mid.empty, unienv_of_hyps hyps) in
      let p        = TT.trans_pattern env (ps, ue) f in
      let ev       = EV.of_idents (Mid.keys !ps) in
    
      let (tvi, tparams, body, args) =
        match sform_of_form p with
        | SFop (p, args) -> begin
            let op = EcEnv.Op.by_path (fst p) env in
            match op.EcDecl.op_kind with
            | EcDecl.OB_oper None | EcDecl.OB_pred None ->
                tacuerror "this operator/predicate is abstract"
            | EcDecl.OB_oper (Some (EcDecl.OP_Constr _)) ->
                tacuerror "this operator is a constructor"
            | EcDecl.OB_oper (Some (EcDecl.OP_Record _)) ->
                tacuerror "this operator is a record constructor"
            | EcDecl.OB_oper (Some (EcDecl.OP_Proj _)) ->
                tacuerror "this operator is a projection"
            | EcDecl.OB_oper (Some (EcDecl.OP_Fix _)) ->
                tacuerror "this operator is a match-fix"
            | EcDecl.OB_oper (Some (EcDecl.OP_Plain e)) ->
                (snd p, op.EcDecl.op_tparams, form_of_expr EcFol.mhr e, args)
            | EcDecl.OB_pred (Some f) ->
                (snd p, op.EcDecl.op_tparams, f, args)
        end

        | SFlocal x when LDecl.reducible_var x hyps ->
            ([], [], LDecl.reduce_var x hyps, [])

        | _ -> tacuerror "not headed by an operator/predicate"
      in

      let na = List.length args in

      match s with
      | `LtoR -> begin
        let ctxt = try_match hyps (ue, ev) p concl in
  
        match ctxt with
        | None -> t_id None g
        | Some (_ue, tue, ev) -> begin
            let p    = concretize_form (tue, ev) p in
            let cpos =
              let test = fun _ fp ->
                let fp =
                  match fp.f_node with
                  | Fapp (h, hargs) when List.length hargs > na ->
                      let (a1, a2) = List.take_n na hargs in
                        f_app h a1 (toarrow (List.map f_ty a2) fp.f_ty)
                  | _ -> fp
                in
                  if   EcReduction.is_alpha_eq hyps p fp
                  then Some (-1)
                  else None
              in
                try  FPosition.select ?o test concl
                with InvalidOccurence ->
                  tacuerror "invalid occurences selector"
            in
      
            let concl =
              FPosition.map cpos
                (fun topfp ->
                  let (fp, args) = EcFol.destr_app topfp in

                  match sform_of_form fp with
                  | SFop ((_, tvi), []) -> begin
                    (* FIXME: TC HOOK *)
                    let subst = EcTypes.Tvar.init (List.map fst tparams) tvi in
                    let body  = EcFol.Fsubst.subst_tvar subst body in
                    let body  = f_app body args topfp.f_ty in
                      try  EcReduction.h_red EcReduction.beta_red (get_hyps g) body
                      with EcBaseLogic.NotReducible -> body
                  end

                  | SFlocal _ -> begin
                      assert (tparams = []);
                      let body = f_app body args topfp.f_ty in
                        try  EcReduction.h_red EcReduction.beta_red (get_hyps g) body
                        with EcBaseLogic.NotReducible -> body
                  end

                  | _ -> assert false)
                (get_concl g)
            in
              t_change concl g
        end
      end

      | `RtoL ->
        let fp =
          (* FIXME: TC HOOK *)
          let subst = EcTypes.Tvar.init (List.map fst tparams) tvi in
          let body  = EcFol.Fsubst.subst_tvar subst body in
          let fp    = f_app body args p.f_ty in
            try  EcReduction.h_red EcReduction.beta_red (get_hyps g) fp
            with EcBaseLogic.NotReducible -> fp
        in

        let ctxt = try_match hyps (ue, ev) fp concl in
  
        match ctxt with
        | None -> t_id None g
        | Some (_ue, tue, ev) -> begin
          let p    = concretize_form (tue, ev) p  in
          let fp   = concretize_form (tue, ev) fp in
          let cpos =
            try  FPosition.select_form hyps o fp concl
            with InvalidOccurence ->
              tacuerror "invalid occurences selector"
          in

          let concl = FPosition.map cpos (fun _ -> p)  concl in
            t_change concl g
        end
  end

  | RWRw (s, r, o, l) ->
      let do1 pe g =
        let hyps = get_hyps g in
        let (p, typs, ue, ax) =
          process_pterm loc (process_formula hyps) hyps pe in
        let args = List.map (trans_pterm_argument hyps ue) pe.fp_args in
          process_rewrite1_core (s, o) (p, typs, ue, ax) args g in
      let doall = t_lor (List.map do1 l) in

        match r with
        | None -> doall g
        | Some (b, n) -> t_do b n doall g

(* -------------------------------------------------------------------- *)
let process_rewrite loc ri (juc, n) =
  let do1 gs (fc, ri) =
    let tx =
      match fc with
      | None    -> t_on_goals
      | Some fc -> t_focus fc.pl_desc
    in
      tx (process_rewrite1 loc ri) gs
  in
    set_loc loc (fun () -> List.fold_left do1 (juc, [n]) ri) ()

(* -------------------------------------------------------------------- *)
let process_elim loc pe ((_, n) as g) =
  let ((juc, an), gs) = process_mkn_apply (process_formula (get_hyps g)) pe g in
  let (_, f) = get_node (juc, an) in

    t_on_first (t_use an gs) (set_loc loc (t_elim f) (juc, n))

(* -------------------------------------------------------------------- *)
let process_exists fs g =
  gen_t_exists check_pterm_arg_for_ty fs g

(* -------------------------------------------------------------------- *)
let process_change pf g =
  let f = process_formula (get_hyps g) pf in
    set_loc pf.pl_loc (t_change f) g

(* -------------------------------------------------------------------- *)
let process_intros ?(cf = true) pis (juc, n) =
  let mk_intro ids g =
    t_intros (snd (List.map_fold (fun (hyps, form) s ->
      let rec destruct fp =
        match EcFol.sform_of_form fp with
        | SFquant (Lforall, (x, _)  , fp) -> (EcIdent.name x, fp)
        | SFlet   (LSymbol (x, _), _, fp) -> (EcIdent.name x, fp)
        | SFimp   (_                , fp) -> ("H", fp)
        | _ -> begin
          match EcReduction.h_red_opt EcReduction.full_red hyps fp with
          | None   -> ("_", f_true)
          | Some f -> destruct f
        end
      in
      let name, form = destruct form in
      let id = 
        lmap (function
        | `NoName       -> EcIdent.create "_"
        | `FindName     -> LDecl.fresh_id hyps name
        | `NoRename s   -> EcIdent.create s
        | `WithRename s -> LDecl.fresh_id hyps s) s
      in

      let hyps = LDecl.add_local id.pl_desc (LD_var (tbool, None)) hyps in
        (hyps, form), id)
      (get_goal g) ids)) g
  in

  let elim_top g =
    let h       = EcIdent.create "_" in
    let (g, an) = EcLogic.t_intros_1 [h] g in
    let (g, n)  =
      try  mkn_hyp g (get_hyps (g, an)) h
      with LDecl.Ldecl_error _ -> tacuerror "nothing to elim" in
    let f       = snd (get_node (g, n)) in
      t_on_goals
        (t_clear (EcIdent.Sid.of_list [h]))
        (t_on_first (t_use n []) (t_elim f (g, an))) in

  let rec collect acc core pis =
    let maybe_core () =
      match core with
      | [] -> acc
      | _  -> `Core (List.rev core) :: acc
    in

    match pis with
    | [] -> maybe_core ()

    | IPCore x :: pis -> collect acc (x :: core) pis

    | IPDone b :: pis ->
        collect (`Done b :: maybe_core ()) [] pis

    | IPSimplify :: pis ->
        collect (`Simpl :: maybe_core ()) [] pis

    | IPClear xs :: pis ->
        collect (`Clear xs :: maybe_core ()) [] pis

    | IPCase x :: pis ->
        let x = List.map (List.rev -| collect [] []) x in
          collect (`Case x :: maybe_core ()) [] pis

    | IPRw x :: pis ->
        collect (`Rw x :: maybe_core ()) [] pis
  in

  let rec dointro nointro pis (gs : goals) =
    let (_, gs) =
      List.fold_left
        (fun (nointro, gs) ip ->
          match ip with
          | `Core ids ->
              (false, t_on_goals (mk_intro ids) gs)

          | `Done b   ->
              let t =
                match b with
                | true  -> t_seq t_simplify_nodelta process_trivial
                | false -> process_trivial
              in
                (nointro, t_on_goals t gs)

          | `Simpl ->
              (nointro, t_on_goals t_simplify_nodelta gs)

          | `Clear xs ->
              (nointro, t_on_goals (process_clear xs) gs)

          | `Case pis ->
              let gs =
                match nointro && not cf with
                | true  -> t_subgoal (List.map (dointro1 false) pis) gs
                | false -> begin
                    match pis with
                    | [] -> t_on_goals elim_top gs
                    | _  ->
                        let t gs =
                          t_subgoal (List.map (dointro1 false) pis) (elim_top gs)
                        in
                          t_on_goals t gs
                end
              in
                (false, gs)

          | `Rw (o, s) ->
              let t g =
                let h  = EcIdent.create "_" in

                let rwt g =
                  let ue = unienv_of_hyps (get_hyps g) in
                  let eq = LDecl.lookup_hyp_by_id h (get_hyps g) in
                    process_rewrite1_core (s, o) (`Local h, [], ue, eq) [] g
                in
                  t_lseq [t_intros_i [h]; rwt; t_clear (Sid.singleton h)] g
              in
                (false, t_on_goals t gs))

        (nointro, gs) pis
    in
      gs

  and dointro1 nointro pis (juc, n) = dointro nointro pis (juc, [n]) in

    dointro1 true (List.rev (collect [] [] pis)) (juc, n)

(* -------------------------------------------------------------------- *)
let process_cut (engine : engine) ip phi t g =
  let phi = process_formula (get_hyps g) phi in
  let g   = t_cut phi g in
  let g   =
    match t with
    | None   -> g
    | Some t -> t_on_first (engine t) g
  in

  match ip with None -> g | Some ip -> t_on_last (process_intros [ip]) g

(* -------------------------------------------------------------------- *)
let process_cutdef loc ip cd g =
  let (hyps, _) = (get_hyps g, get_concl g) in
  let (p, typs, ue, ax) = process_named_pterm loc hyps (cd.pt_name, cd.pt_tys) in
  let args = List.map (trans_pterm_argument hyps ue) cd.pt_args in
  let (ax, ids) = check_pterm_arguments hyps ue ax args in
  let ev = evmap_of_pterm_arguments ids in

    if not (can_concretize_pterm_arguments (ue, ev) ids) then
      tacuerror ~loc "cannot infer all placeholders";

  let tue = EcUnify.UniEnv.close ue in
  let args = concretize_pterm_arguments (tue, ev) ids in
  let ax   = concretize_pterm (tue, ev) ids ax in
  let typs = List.map (Tuni.offun tue) typs in
  let g    = t_cut ax g in
  let g    =
    let tt g =
      match p with
      | `Global p -> gen_t_apply_glob (fun _ _ x -> x) p typs args g
      | `Local  x -> gen_t_apply_hyp  (fun _ _ x -> x) x args g
    in
      t_on_first tt g
  in

  match ip with None -> g | Some ip -> t_on_last (process_intros [ip]) g

(* -------------------------------------------------------------------- *)
let process_pose loc xsym o p g =
  let (hyps, concl) = get_goal g in
  let env = LDecl.toenv hyps in
  let (ps, ue) = (ref Mid.empty, unienv_of_hyps hyps) in
  let p   = TT.trans_pattern env (ps, ue) p in
  let ids = Mid.keys !ps in
  let ev  = EV.of_idents ids in

  let (_ue, tue, ev, dopat) =
    match try_match hyps (ue, ev) p concl with
    | Some (ue, tue, ev) -> (ue, tue, ev, true)
    | None -> begin
        let ids = List.map (fun x -> `UnknownVar (x, ())) ids in
        if not (can_concretize_pterm_arguments (ue, ev) ids) then begin
          if   ids = []
          then tacuerror "%s - %s"
                 "cannot find an occurence for [pose]"
                 "instanciate type variables manually"
          else tacuerror "cannot find an occurence for [pose]";
        end;
        let ue = EcUnify.UniEnv.copy ue in
          (ue, EcUnify.UniEnv.close ue, ev, false)
    end
  in

  let p = concretize_form (tue, ev) p in
  let (x, letin) =
    match dopat with
    | false -> (EcIdent.create (unloc xsym), concl)
    | true  -> begin
        let cpos =
          try  FPosition.select_form hyps o p concl
          with InvalidOccurence -> tacuerror "invalid occurence selector"
        in
          FPosition.topattern ~x:(EcIdent.create (unloc xsym)) cpos concl
    end
  in

  let letin = EcFol.f_let1 x p letin in
    set_loc loc
      (t_seq (t_change letin) (t_intros [mk_loc xsym.pl_loc x]))
      g

(* -------------------------------------------------------------------- *)
let process_generalize l =
  let pr1 (occ, pf) g =
    let hyps = get_hyps g in
    match pf.pl_desc with
    | PFident ({pl_desc = ([], s)}, None)
        when occ = None && LDecl.has_symbol s hyps
        ->
      let id = fst (LDecl.lookup s hyps) in
        t_seq (t_generalize_hyp id) (t_clear (Sid.singleton id)) g

    | _ ->
      let (hyps, concl) = get_goal g in
      let env = LDecl.toenv hyps in
      let (ps, ue) = (ref Mid.empty, unienv_of_hyps hyps) in
      let p = TT.trans_pattern env (ps, ue) pf in
      let ev = EV.of_idents (Mid.keys !ps) in
    
      let (_ue, tue, ev) =
        match try_match hyps (ue, ev) p concl with
        | None   -> tacuerror "cannot find an occurence for [generalize]"
        | Some x -> x
      in
    
      let p    = concretize_form (tue, ev) p in
      let cpos =
        try  FPosition.select_form hyps occ p concl
        with InvalidOccurence -> tacuerror "invalid occurence selector"
      in

      let name =
        match EcParsetree.pf_ident pf with
        | None   -> EcIdent.create "x"
        | Some x -> EcIdent.create x
      in

      let fpat _ _ _ = FPosition.topattern ~x:name cpos concl in
        t_generalize_form ~fpat None p g

  in
    t_lseq (List.rev_map pr1 l)

(* -------------------------------------------------------------------- *)
let process_elimT loc (pf, qs) g =
  let noelim () = tacuerror "cannot recognize elimination principle" in

  let (hyps, concl) = get_goal g in

  let pf = process_form_opt hyps pf None in
  let qs =
    match qs with
    | Some qs -> qs
    | None    -> begin
        match EcEnv.Ty.scheme_of_ty pf.f_ty (LDecl.toenv hyps) with
        | None    -> noelim ()
        | Some qs -> mk_loc loc (EcPath.toqsymbol qs)
    end
  in

  let (p, typs, ue, ax) =
    match process_named_pterm loc hyps (qs, None) with
    | (`Global p, typs, ue, ax) -> (p, typs, ue, ax)
    | _ -> noelim ()
  in

  let (_xp, xpty, ax) =
    match destruct_product hyps ax with
    | Some (`Forall (xp, GTty xpty, f)) -> (xp, xpty, f)
    | _ -> noelim ()
  in

  begin
    try  EcUnify.unify (LDecl.toenv hyps) ue (tfun pf.f_ty tbool) xpty
    with EcUnify.UnificationFailure _ -> noelim ()
  end;

  let tue =
    try  EcUnify.UniEnv.close ue
    with EcUnify.UninstanciateUni -> noelim ()
  in

  let ax = Fsubst.uni tue ax in

  let rec skip ax =
    match destruct_product hyps ax with
    | Some (`Imp (_f1, f2)) -> skip f2
    | Some (`Forall (x, GTty xty, f)) -> ((x, xty), f)
    | _ -> noelim ()
  in

  let ((x, _xty), ax) = skip ax in

  let ptnpos = FPosition.select_form hyps None pf concl in

  if FPosition.is_empty ptnpos then noelim ();

  let (_xabs, body) = FPosition.topattern ~x:x ptnpos concl in

  let rec skipmatch ax body sk =
    match destruct_product hyps ax, destruct_product hyps body with
    | Some (`Imp (i1, f1)), Some (`Imp (i2, f2)) ->
        if   EcReduction.is_alpha_eq hyps i1 i2
        then skipmatch f1 f2 (sk+1)
        else sk
    | _ -> sk
  in

  let sk = skipmatch ax body 0 in

  t_seq
    (set_loc loc (t_elimT (List.map (Tuni.offun tue) typs) p pf sk))
    (t_simplify EcReduction.beta_red) g

(* -------------------------------------------------------------------- *)
let process_algebra mode kind eqs g =
  let (env, hyps, concl) = get_goal_e g in

  if not (EcAlgTactic.is_module_loaded env) then
    tacuerror "ring/field cannot be used when AlgTactic is not loaded";

  let (ty, f1, f2) =
    match sform_of_form concl with
    | SFeq (f1, f2) -> (f1.f_ty, f1, f2)
    | _ -> tacuerror "conclusion must be an equation"
  in

  let eqs =
    let eq1 { pl_desc = x } =
      match LDecl.has_hyp x hyps with
      | false -> tacuerror "cannot find equation referenced by `%s'" x
      | true  -> begin
        match sform_of_form (snd (LDecl.lookup_hyp x hyps)) with
        | SFeq (f1, f2) ->
            if not (EcReduction.EqTest.for_type env ty f1.f_ty) then
              tacuerror "assumption `%s' is not an equation over the right type" x;
            (f1, f2)
        | _ -> tacuerror "assumption `%s' is not an equation" x
      end
    in List.map eq1 eqs
  in

  let tactic =
    match
      match mode, kind with
      | `Simpl, `Ring  -> `Ring  EcAlgTactic.t_ring_simplify
      | `Simpl, `Field -> `Field EcAlgTactic.t_field_simplify
      | `Solve, `Ring  -> `Ring  EcAlgTactic.t_ring
      | `Solve, `Field -> `Field EcAlgTactic.t_field
    with
    | `Ring t ->
        let r =
          match EcEnv.Algebra.get_ring ty env with
          | None   -> tacuerror "cannot find a ring structure"
          | Some r -> r
        in t r eqs (f1, f2)
    | `Field t ->
        let r =
          match EcEnv.Algebra.get_field ty env with
          | None   -> tacuerror "cannot find a field structure"
          | Some r -> r
        in t r eqs (f1, f2)
  in
    tactic g

(* -------------------------------------------------------------------- *)
let process_logic (engine, hitenv) loc t =
  match t with
  | Preflexivity   -> process_reflexivity loc
  | Passumption pq -> process_assumption loc pq
  | Psmt pi        -> process_smt hitenv pi
  | Pintro pi      -> process_intros pi
  | Psplit         -> t_split
  | Pfield st      -> process_algebra `Solve `Field st
  | Pring st       -> process_algebra `Solve `Ring  st
  | Pexists fs     -> process_exists fs
  | Pleft          -> t_left
  | Pright         -> t_right
  | Pcongr         -> process_congr
  | Ptrivial       -> process_trivial
  | Pelim pe       -> process_elim loc pe
  | Papply pe      -> process_apply loc pe
  | Pcut (ip, f, t)-> process_cut engine ip f t
  | Pcutdef (ip, f)-> process_cutdef loc ip f
  | Pgeneralize l  -> process_generalize l
  | Pclear l       -> process_clear l
  | Prewrite ri    -> process_rewrite loc ri
  | Psubst   ri    -> process_subst loc ri
  | Psimplify ri   -> process_simplify ri
  | Pchange pf     -> process_change pf
  | PelimT i       -> process_elimT loc i
  | Ppose (x, o, p)-> process_pose loc x o p
