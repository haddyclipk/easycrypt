(* --------------------------------------------------------------------
 * Copyright (c) - 2012--2016 - IMDEA Software Institute
 * Copyright (c) - 2012--2018 - Inria
 * Copyright (c) - 2012--2018 - Ecole Polytechnique
 *
 * Distributed under the terms of the CeCILL-B-V1 license
 * -------------------------------------------------------------------- *)

(* -------------------------------------------------------------------- *)
require import AllCore List.

(* ==================================================================== *)
abstract theory FinType.
type t.

op enum : t list.

op card : int = size enum.

axiom enum_spec : forall x, count (pred1 x) enum = 1.

(* -------------------------------------------------------------------- *)
lemma enumP : forall x, mem enum x.
proof.
move=> x; have: 0 < count (pred1 x) enum by rewrite enum_spec.
by move/has_count/hasP; case=> y [h @/pred1 <-].
qed.

lemma enum_uniq : uniq enum.
proof. by apply/count_mem_uniq=> x; rewrite enumP enum_spec. qed.

lemma card_gt0 : 0 < card.
proof.
rewrite /card; have: mem enum witness by rewrite enumP.
by case: enum=> //= x s _; rewrite addzC ltzS size_ge0.
qed.
end FinType.

(* ==================================================================== *)
abstract theory FinProdType.
clone FinType as FT1.
clone FinType as FT2.

clone include FinType
  with type t    = FT1.t * FT2.t,
         op enum = allpairs (fun x y => (x, y)) FT1.enum FT2.enum
  proof *.

realize enum_spec.
proof.
case=> x y; rewrite count_uniq_mem.
+ by apply/allpairs_uniq => //; [apply FT1.enum_uniq | apply FT2.enum_uniq].
+ by apply/b2i_eq1/allpairsP; exists (x, y); rewrite !(FT1.enumP, FT2.enumP).
qed.
end FinProdType.
