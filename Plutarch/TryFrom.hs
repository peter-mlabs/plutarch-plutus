{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}

module Plutarch.TryFrom (
  PTryFrom (..),
  HRecP (..),
  ptryFromData,
) where

import Data.Proxy (Proxy (Proxy))

import GHC.Records (HasField (getField))
import GHC.TypeLits (KnownNat, Nat, Symbol, natVal, type (+))

import Plutarch.Unsafe (punsafeCoerce, punsafeFrom)

import Plutarch.Bool (pif, (#==))
import Plutarch.ByteString (PByteString)
import Plutarch.Integer (PInteger)
import Plutarch.Unit (PUnit (PUnit))

import Plutarch.Internal.Other (
  DerivePNewtype,
  PInner,
  POpaque,
  PType,
  S,
  Term,
  pcon,
  pdelay,
  pforce,
  plam,
  plet,
  popaque,
  (#),
  type (:-->),
 )

import Plutarch.Trace (ptraceError)

import Plutarch.DataRepr.Internal (
  PDataRecord,
  PDataSum,
  PLabeledType ((:=)),
  pdnil,
 )

import Plutarch.List (
  phead,
  pmap,
  ptail,
 )

import Plutarch.Builtin (
  PAsData,
  PBuiltinList,
  PBuiltinMap,
  PBuiltinPair,
  PData,
  PIsData (pfromData),
  pasByteStr,
  pasConstr,
  pasInt,
  pasList,
  pasMap,
  pchooseListBuiltin,
  pdata,
  pforgetData,
  pfstBuiltin,
  ppairDataBuiltin,
  psndBuiltin,
 )

import Plutarch.TermCont (TermCont (TermCont, runTermCont), tcont, unTermCont)

import Plutarch.DataRepr.Internal (PIsDataRepr (PIsDataReprRepr), PIsDataReprInstances)

import Plutarch.Reducible (Reducible (Reduce))

import Data.Functor.Const (Const)

----------------------- The class PTryFrom ----------------------------------------------

{- |
    This checks the data structure for validity.
    If you don't care about parts of the structure
    don't verify those parts, just put a `PData` at
    the places you don't care about.
    Be aware this might get really expensive, so only
    use it if you cannot establish trust otherwise
    (e.g. via only checking a part of your Data with
    PTryFrom)
    Laws:
      - the operation `ptryFrom` mustn't change the representation of the underlying data
      - the operation `ptryFrom` must always prove the integrity of the whole target type
        - example:
          `ptryFrom PData (PAsData (PBuiltinList PData))` must only succeed if the underlying
          representation is a `BuiltinList` containing any `PData`
        - all conversions are fallible, this happens if the representation doesn't match
          the expected type.
      - the operation `ptryFrom @a @b` proves equality between the less expressive `PType` `a` and
        the more expressive `PType` `b`, hence the first element of the resulting Tuple
        must always be wrapped in `PAsData` if the origin type was `PData` (see law 1)
      - the result type `b` must always be safe than the origin type `a`, i.e. it must carry
        more information
-}
class PTryFrom (a :: PType) (b :: PType) where
  type PTryFromExcess a b :: PType
  ptryFrom :: forall s r. Term s a -> ((Term s b, Reduce (PTryFromExcess a b s)) -> Term s r) -> Term s r

-- | Utility function that saves a type application, `ptryFromData @b === ptryFrom @PData @b`
ptryFromData ::
  forall b s r.
  ( PTryFrom PData b
  ) =>
  Term s PData ->
  ((Term s b, Reduce (PTryFromExcess PData b s)) -> Term s r) ->
  Term s r
ptryFromData = ptryFrom @PData @b

----------------------- Reducible and Flip ----------------------------------------------

instance Reducible (HRecP as s) where type Reduce (HRecP as s) = HRecP as s

instance Reducible (f x y) => Reducible (Flip f y x) where
  type Reduce (Flip f y x) = Reduce (f x y)

newtype Flip f a b = Flip (f b a)

----------------------- HRecP and friends -----------------------------------------------

-- | Like @HRec@ but parametrised over a list of `PType`s, not `Type`s.
data HRecP (as :: [(Symbol, PType)]) (s :: S) where
  HNil :: HRecP '[] s
  HCons :: forall name a as s. Reduce (a s) -> HRecP as s -> HRecP ('(name, a) ': as) s

{- | allows accessing excess fields in an HRec, as of ghc921 you can
 also use `OverloadedRecordDot` with this.
-}
getExcessField ::
  forall name a as s.
  ( ElemOf name a as
  ) =>
  HRecP as s ->
  Reduce (a s)
getExcessField xs = indexHRec xs $ elemOf @name @a @as

-- | Index HRec using Elem
indexHRec :: forall s as. HRecP as s -> (forall a name. Elem name a as -> Reduce (a s))
indexHRec (HCons x _) Here = x
indexHRec (HCons _ xs) (There i) = indexHRec xs i
indexHRec HNil impossible = case impossible of {}

data Elem (sym :: Symbol) (a :: PType) (as :: [(Symbol, PType)]) where
  Here :: Elem sym a ('(sym, a) ': as)
  There :: Elem a sym as -> Elem a sym ('(sym', b) ': as)

class
  ElemOf (name :: Symbol) (a :: PType) (as :: [(Symbol, PType)])
    | as name -> a
  where
  elemOf :: Elem name a as

instance {-# OVERLAPPING #-} ElemOf name a ('(name, a) ': as) where
  elemOf = Here

instance
  {-# OVERLAPPABLE #-}
  ( ElemOf name a as
  ) =>
  ElemOf name a ('(name', b) ': as)
  where
  elemOf :: Elem name a ('(name', b) ': as)
  elemOf = There (elemOf @name @a @as)

----------------------- PData instances -------------------------------------------------

instance PTryFrom PData (PAsData PInteger) where
  type PTryFromExcess PData (PAsData PInteger) = Flip Term PInteger
  ptryFrom opq = runTermCont $ do
    ver <- tcont $ plet (pasInt # opq)
    pure $ (punsafeCoerce opq, ver)

instance PTryFrom PData (PAsData PByteString) where
  type PTryFromExcess PData (PAsData PByteString) = Flip Term PByteString
  ptryFrom opq = runTermCont $ do
    ver <- tcont $ plet (pasByteStr # opq)
    pure $ (punsafeCoerce opq, ver)

instance
  ( PTryFrom PData (PAsData a)
  , PTryFrom PData (PAsData b)
  ) =>
  PTryFrom PData (PAsData (PBuiltinMap a b))
  where
  type PTryFromExcess PData (PAsData (PBuiltinMap a b)) = Flip Term (PBuiltinMap a b)
  ptryFrom opq = runTermCont $ do
    verMap <- tcont $ plet (pasMap # opq)
    let verifyPair :: Term _ (PBuiltinPair PData PData :--> PBuiltinPair (PAsData a) (PAsData b))
        verifyPair = plam $ \tup -> unTermCont $ do
          (verfst, _) <- tcont $ ptryFromData @(PAsData a) $ pfstBuiltin # tup
          (versnd, _) <- tcont $ ptryFromData @(PAsData b) $ psndBuiltin # tup
          pure $ ppairDataBuiltin # verfst # versnd
    ver <- tcont $ plet $ pmap # verifyPair # verMap
    pure (punsafeCoerce opq, ver)

{- |
    This verifies a list to be indeed a list but doesn't recover the inner data
    use this instance instead of the one for `PData (PAsData (PBuiltinList (PAsData a)))`
    as this is O(1) instead of O(n)
-}

-- TODO: add the excess inner type list
instance PTryFrom PData (PAsData (PBuiltinList PData)) where
  type PTryFromExcess PData (PAsData (PBuiltinList PData)) = Flip Term (PBuiltinList PData)
  ptryFrom opq = runTermCont $ do
    ver <- tcont $ plet (pasList # opq)
    pure $ (punsafeCoerce opq, ver)

{- |
    Recover a `PBuiltinList (PAsData a)`
-}
instance
  ( PTryFrom PData (PAsData a)
  , PIsData a
  ) =>
  PTryFrom PData (PAsData (PBuiltinList (PAsData a)))
  where
  type PTryFromExcess PData (PAsData (PBuiltinList (PAsData a))) = Flip Term (PBuiltinList (PAsData a))
  ptryFrom opq = runTermCont $ do
    let lst :: Term _ (PBuiltinList PData)
        lst = pasList # opq
        verify :: Term _ (PData :--> PAsData a)
        verify = plam $ \e ->
          unTermCont $ do
            (wrapped, _) <- tcont $ ptryFromData @(PAsData a) $ e
            pure wrapped
    ver <- tcont $ plet $ pmap # verify # lst
    pure $ (punsafeCoerce opq, ver)

{- |
    Recover a `PAsData (PBuiltinPair a b)`
-}
instance
  ( PTryFrom PData a
  , a ~ PAsData a'
  , PIsData a'
  , PTryFrom PData b
  , b ~ PAsData b'
  , PIsData b'
  ) =>
  PTryFrom PData (PAsData (PBuiltinPair a b))
  where
  type PTryFromExcess PData (PAsData (PBuiltinPair a b)) = Flip Term (PBuiltinPair a b)
  ptryFrom opq = runTermCont $ do
    tup <- tcont $ plet (pfromData $ punsafeCoerce opq)
    let fst' :: Term _ a
        fst' = unTermCont $ fst <$> tcont (ptryFromData @a $ pforgetData $ pfstBuiltin # tup)
        snd' :: Term _ b
        snd' = unTermCont $ fst <$> tcont (ptryFromData @b $ pforgetData $ psndBuiltin # tup)
    ver <- tcont $ plet $ ppairDataBuiltin # fst' # snd'
    pure $ (punsafeCoerce opq, ver)

----------------------- PDataRecord instances -------------------------------------------

-- We could have a more advanced instance but it's not needed really.

newtype ExcessForField (a :: PType) (s :: S) = ExcessForField (Term s (PAsData a), Reduce (PTryFromExcess PData (PAsData a) s))

instance Reducible (PTryFromExcess PData (PAsData a) s) => Reducible (ExcessForField a s) where
  type Reduce (ExcessForField a s) = (Term s (PAsData a), Reduce (PTryFromExcess PData (PAsData a) s))

-- FIXME: Should we always succede? If we always succede, performance would increase a lot.
instance PTryFrom (PBuiltinList PData) (PDataRecord '[]) where
  type PTryFromExcess (PBuiltinList PData) (PDataRecord '[]) = HRecP '[]
  ptryFrom opq = runTermCont $ do
    _ :: Term _ PUnit <-
      tcont . plet . pforce $
        pchooseListBuiltin # opq # pdelay (pcon PUnit) # pdelay (ptraceError "list is longer than zero")
    pure (pdnil, HNil)

type family UnHRecP (x :: PType) :: [(Symbol, PType)] where
  UnHRecP (HRecP as) = as

instance
  ( PTryFrom PData (PAsData pty)
  , PTryFrom (PBuiltinList PData) (PDataRecord as)
  , PTryFromExcess (PBuiltinList PData) (PDataRecord as) ~ HRecP ase
  ) =>
  PTryFrom (PBuiltinList PData) (PDataRecord ((name ':= pty) ': as))
  where
  type
    PTryFromExcess (PBuiltinList PData) (PDataRecord ((name ':= pty) ': as)) =
      HRecP
        ( '(name, ExcessForField pty)
            ': UnHRecP (PTryFromExcess (PBuiltinList PData) (PDataRecord as))
        )
  ptryFrom opq = runTermCont $ do
    h <- tcont $ plet $ phead # opq
    hv <- tcont $ ptryFrom @PData @(PAsData pty) h
    t <- tcont $ plet $ ptail # opq
    tv <- tcont $ ptryFrom @(PBuiltinList PData) @(PDataRecord as) t
    pure (punsafeCoerce opq, HCons hv (snd tv))

newtype Helper a b s = Helper (a s, b s)

instance (Reducible (a s), Reducible (b s)) => Reducible (Helper a b s) where
  type Reduce (Helper a b s) = (Reduce (a s), Reduce (b s))

instance
  ( PTryFrom (PBuiltinList PData) (PDataRecord as)
  , PTryFromExcess (PBuiltinList PData) (PDataRecord as) ~ HRecP ase
  ) =>
  PTryFrom PData (PAsData (PDataRecord as))
  where
  type
    PTryFromExcess PData (PAsData (PDataRecord as)) =
      Helper (Flip Term (PDataRecord as)) (PTryFromExcess (PBuiltinList PData) (PDataRecord as))
  ptryFrom opq = runTermCont $ do
    l <- snd <$> (tcont $ ptryFromData @(PAsData (PBuiltinList PData)) opq)
    r <- tcont $ ptryFrom @_ @(PDataRecord as) l
    pure (punsafeCoerce opq, r)

instance {-# OVERLAPPING #-} SumValidation 0 ys => PTryFrom PData (PAsData (PDataSum ys)) where
  type PTryFromExcess PData (PAsData (PDataSum ys)) = Const ()
  ptryFrom opq = runTermCont $ do
    x <- tcont $ plet $ pasConstr # opq
    constr <- tcont $ plet $ pfstBuiltin # x
    fields <- tcont $ plet $ psndBuiltin # x
    _ <- tcont $ plet $ validateSum @0 @ys constr fields
    pure (punsafeCoerce opq, ())

class SumValidation (n :: Nat) (sum :: [[PLabeledType]]) where
  validateSum :: Term s PInteger -> Term s (PBuiltinList PData) -> Term s POpaque

instance
  {-# OVERLAPPABLE #-}
  forall (n :: Nat) (x :: [PLabeledType]) (xs :: [[PLabeledType]]).
  ( PTryFrom (PBuiltinList PData) (PDataRecord x)
  , SumValidation (n + 1) xs
  , KnownNat n
  ) =>
  SumValidation n (x ': xs)
  where
  validateSum constr fields =
    pif
      (fromInteger (natVal $ Proxy @n) #== constr)
      ( unTermCont $ do
          _ <- tcont $ ptryFrom @_ @(PDataRecord x) fields
          pure $ popaque $ pcon PUnit
      )
      (validateSum @(n + 1) @xs constr fields)

instance {-# OVERLAPPING #-} SumValidation n '[] where
  validateSum _ _ = ptraceError "reached end of sum while still not having found the constructor"

----------------------- other utility functions -----------------------------------------

{- | if there is an instance to recover something that is unwrapped from something that is
 unwrapped, then there is also the possibility to recover the whole thing but wrapped
-}
instance
  ( PTryFrom a b
  , PIsData a
  , PIsData b
  ) =>
  PTryFrom (PAsData a) (PAsData b)
  where
  type PTryFromExcess (PAsData a) (PAsData b) = PTryFromExcess a b
  ptryFrom opq = runTermCont $ do
    ver' <- snd <$> TermCont (ptryFrom @a @b (pfromData opq))
    pure $ (punsafeCoerce opq, ver')

instance PTryFrom PData PData where
  type PTryFromExcess PData PData = Const ()
  ptryFrom opq = runTermCont $ pure $ (opq, ())

instance PTryFrom PData (PAsData PData) where
  type PTryFromExcess PData (PAsData PData) = Const ()
  ptryFrom opq = runTermCont $ pure (pdata opq, ())

----------------------- PIsDataReprInstances instance -----------------------------------

-- | you can instantiate `PTryFrom` for your own datatype as demonstrated in the spec
instance
  ( PIsDataRepr a
  , SumValidation 0 (PIsDataReprRepr a)
  , PInner a b ~ PDataSum (PIsDataReprRepr a)
  ) =>
  PTryFrom PData (PAsData (PIsDataReprInstances a))
  where
  type PTryFromExcess PData (PAsData (PIsDataReprInstances a)) = HRecP '[]
  ptryFrom opq = runTermCont $ do
    let reprsum :: Term _ (PDataSum (PIsDataReprRepr a))
        reprsum = pfromData $ unTermCont $ fst <$> TermCont (ptryFrom opq)
    pure $ (pdata $ punsafeFrom reprsum, HNil)

----------------------- DerivePNewtype insatace -----------------------------------------

instance
  ( PTryFrom a b
  ) =>
  PTryFrom a (DerivePNewtype c b)
  where
  type PTryFromExcess a (DerivePNewtype c b) = PTryFromExcess a b
  ptryFrom opq = runTermCont $ (\(inn, exc) -> (punsafeFrom inn, exc)) <$> tcont (ptryFrom @a @b opq)

----------------------- HasField instance -----------------------------------------------

{-
instance (ElemOf name ptyp rec, Reduce (ptyp s) ~ out) => HasField name (HRecP rec s) out where
  getField = getExcessField @name
-}
