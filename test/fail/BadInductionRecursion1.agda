
module BadInductionRecursion1 where

data Unit : Set where
  unit : Unit

mutual
  D′ : Unit -> Set

  data D : Set where
    d : forall u -> (D′ u -> D′ u) -> D

  D′ unit = D

_·_ : D -> D -> D
d unit f · x = f x

ω : D 
ω = d unit (\x -> x · x)

Ω : D
Ω = ω · ω
