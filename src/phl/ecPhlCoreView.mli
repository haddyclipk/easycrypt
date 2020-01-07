(* --------------------------------------------------------------------
 * Copyright (c) - 2012--2016 - IMDEA Software Institute
 * Copyright (c) - 2012--2018 - Inria
 * Copyright (c) - 2012--2018 - Ecole Polytechnique
 *
 * Distributed under the terms of the CeCILL-C-V1 license
 * -------------------------------------------------------------------- *)

(* --------------------------------------------------------------------- *)
open EcCoreGoal.FApi

(* -------------------------------------------------------------------- *)
val t_hoare_of_bdhoareS : backward
val t_hoare_of_bdhoareF : backward
val t_hoare_of_choareS  : backward
val t_hoare_of_choareF  : backward
val t_bdhoare_of_hoareS : backward
val t_bdhoare_of_hoareF : backward
val t_choare_of_hoareS  : backward
val t_choare_of_hoareF  : backward
