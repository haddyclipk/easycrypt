(* -------------------------------------------------------------------- *)
open EcSymbols
open EcPath
open EcTypes
open EcMemory
open EcModules
open EcFol
open EcBaseLogic
open EcLogic

(* -------------------------------------------------------------------- *)
type 'a sdestr_t  = string -> stmt -> 'a * stmt
type 'a sdestr2_t = string -> stmt -> stmt -> 'a * 'a * stmt * stmt

(* -------------------------------------------------------------------- *)
val s_first_asgn    : (lvalue * expr) sdestr_t
val s_first_asgns   : (lvalue * expr) sdestr2_t
val s_first_rnd     : (lvalue * expr) sdestr_t
val s_first_rnds    : (lvalue * expr) sdestr2_t
val s_first_call    : (lvalue option * xpath * expr list) sdestr_t
val s_first_calls   : (lvalue option * xpath * expr list) sdestr2_t
val s_first_if      : (expr * stmt * stmt) sdestr_t
val s_first_ifs     : (expr * stmt * stmt) sdestr2_t
val s_first_while   : (expr * stmt) sdestr_t
val s_first_whiles  : (expr * stmt) sdestr2_t
val s_first_assert  : expr sdestr_t
val s_first_asserts : expr sdestr2_t

(* -------------------------------------------------------------------- *)
val s_last_asgn    : (lvalue * expr) sdestr_t
val s_last_asgns   : (lvalue * expr) sdestr2_t
val s_last_rnd     : (lvalue * expr) sdestr_t
val s_last_rnds    : (lvalue * expr) sdestr2_t
val s_last_call    : (lvalue option * xpath * expr list) sdestr_t
val s_last_calls   : (lvalue option * xpath * expr list) sdestr2_t
val s_last_if      : (expr * stmt * stmt) sdestr_t
val s_last_ifs     : (expr * stmt * stmt) sdestr2_t
val s_last_while   : (expr * stmt) sdestr_t
val s_last_whiles  : (expr * stmt) sdestr2_t
val s_last_assert  : expr sdestr_t
val s_last_asserts : expr sdestr2_t

(* -------------------------------------------------------------------- *)
val t_hS_or_bhS_or_eS : ?th:tactic -> ?tbh:tactic -> ?te:tactic -> tactic

(* -------------------------------------------------------------------- *)
val s_split_i : string -> int -> stmt -> instr list * instr * instr list
val s_split   : string -> int -> stmt -> instr list * instr list
val s_split_o : string -> int option -> stmt -> instr list * instr list

(* -------------------------------------------------------------------- *)
val id_of_pv : prog_var -> memory -> EcIdent.t
val id_of_mp : mpath    -> memory -> EcIdent.t

(* -------------------------------------------------------------------- *)
type lv_subst_t = (lpattern * form) * (prog_var * memory * form) list

val mk_let_of_lv_substs : EcEnv.env -> (lv_subst_t list * form) -> form

val lv_subst : memory -> lvalue -> form -> lv_subst_t

val subst_form_lv : EcEnv.env -> memory -> lvalue -> form -> form -> form
