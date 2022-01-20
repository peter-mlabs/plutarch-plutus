{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Plutarch.Field 
  ( -- * PDataField class & deriving utils
    PDataFields (..)
  , DerivePDataFields
  , pletFields
  , pletNFields
  , pfield
    -- * BindFields class mechanism
  , BindFields (..)
  , type TermsOf
  , type Take
    -- * Re-exports
  , HList (..)
  , HRec (..)
  , hlistField
  , hrecField
  ) where

import GHC.TypeLits (KnownNat, Nat, type (-))
import Data.Proxy (Proxy (..))

import Plutarch.DataRepr 
  (PIsDataRepr (..), PDataRecord, PLabeled (..), type PNames, type PTypes, pdhead, pdtail, pindexDataRecord)
import Plutarch.Internal (TermCont (..), punsafeCoerce)
import Plutarch.Builtin 
  (PAsData, PIsData (..), pasConstr, psndBuiltin, PData)
import Plutarch.Prelude
import Plutarch.Field.HList 
  (HList (..), HRec (..), type SingleItem
  , type IndexList, type IndexOf
  , hrecField, hlistField)



--------------------------------------------------------------------------------
---------- PDataField class & deriving utils

{- |
  Class allowing 'letFields' to work for a PType, usually via
  `PIsDataRepr`, but is derived for some other types for convenience.

-}
class PDataFields (a :: PType) where
  -- | Fields in HRec bound by 'letFields'
  type PFields a :: [PLabeled]

  -- | Convert a Term to a 'PDataList' 
  ptoFields :: Term s a -> Term s (PDataRecord (PFields a))

{- | 
  Derive PDataFields via a 'PIsDataRepr' instance,
  using either 'Numbered' fields or a given list of fields.
-}
data DerivePDataFields (p :: PType) (s :: S)

instance PDataFields (PDataRecord as) where
  type PFields (PDataRecord as) = as
  ptoFields = id

instance 
  forall a as.
  ( PIsDataRepr a
  , SingleItem (PIsDataReprRepr a) ~ as
  ) => PDataFields (DerivePDataFields a) where
  type PFields (DerivePDataFields a) = 
    SingleItem (PIsDataReprRepr a)

  ptoFields t = 
    (punsafeCoerce $ phoistAcyclic $ plam $ \d -> psndBuiltin #$ pasConstr # d)
      # (punsafeCoerce t :: Term _ PData)

instance 
  forall a.
  ( PIsData a
  , PDataFields a
  ) => PDataFields (PAsData a) where
  type PFields (PAsData a) = PFields a
  ptoFields = ptoFields . pfromData 

{- |
  Bind a HRec of named fields from a compatible type.

-}
pletFields :: 
  forall a b s.
  ( PDataFields a
  , BindFields (PFields a)
  ) =>
  Term s a -> (HRec (PNames (PFields a)) (TermsOf s (PTypes (PFields a))) -> Term s b) -> Term s b
pletFields t = runTermCont $
  fmap (HRec @(PNames (PFields a))) $ bindFields $ ptoFields t

pletNFields :: 
  forall n a b s fs ns as.
  ( PDataFields a
  , fs ~ (Take n (PFields a))
  , ns ~ (PNames fs)
  , as ~ (PTypes fs)
  , BindFields fs
  ) =>
  Term s a -> ((HRec ns) (TermsOf s as) -> Term s b) -> Term s b
pletNFields t = runTermCont $
  fmap (HRec @ns) $ bindFields $ to $ ptoFields t
  where
    to :: Term s (PDataRecord (PFields a)) -> Term s (PDataRecord fs)
    to = punsafeCoerce

-- | Map a list of 'PTypes' to the Terms that will be bound by 'bindFields' 
type family TermsOf (s :: S) (as :: [PType]) :: [Type] where
  TermsOf _ '[] = '[]
  TermsOf s (x ': xs) = Term s (PAsData x) ': TermsOf s xs

type family Take (n :: Nat) (as :: [k]) :: [k] where
  Take 0 xs = '[]
  Take n (x ': xs) = x ': (Take (n - 1) xs)

class BindFields (as :: [PLabeled]) where
  {- | 
    Bind all the fields in a 'PDataList' term to a corresponding
    HList of Terms.

    A continuation is returned to enable sharing of
    the generated bound-variables.

  -}
  bindFields :: Term s (PDataRecord as) -> TermCont s (HList (TermsOf s (PTypes as)))

instance  {-# OVERLAPS #-}
  BindFields ((l ':= a) ': '[]) where
  bindFields t =
    pure $ HCons (pdhead # t) HNil

instance {-# OVERLAPPABLE #-}
  (BindFields as) => BindFields ((l ':= a) ': as) where
  bindFields t = do
    t' <- TermCont $ plet t
    --tail <- TermCont $ plet $ pdtail # t 
    xs <- bindFields @as (pdtail # t')
    pure $ HCons (pdhead # t') xs

--
--------------------------------------------------------------------------------

{- |
  Get a single field from a Term.
  Use this where you only need a single field,
  as it is more efficient than the bindings generated by 'letFields'
-}
pfield ::
   forall f p fs a as n s. 
   ( PDataFields p
   , as ~ (PTypes (PFields p))
   , fs ~ (PNames (PFields p))
   , n ~ (IndexOf f fs)
   , KnownNat n
   --, KnownSymbol f
   , a ~ (IndexList n as)
   ) =>
   Term s (p :--> PAsData a)
pfield =
  plam $ \t ->
    pindexDataRecord (Proxy @n) # ptoFields t