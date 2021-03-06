-- | Convert queries into folds.
-- Used in body of group-bys, distincts,...

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
module Icicle.Source.ToCore.Fold (
    convertFold
  , ConvertFoldResult(..)
  , groupMapType
  , groupFoldType
  , groupMapSum
  ) where

import           Icicle.Common.Base
import qualified Icicle.Common.Exp.Prim.Minimal as Min
import qualified Icicle.Common.Exp.Simp.Beta    as Beta
import           Icicle.Common.Fresh
import qualified Icicle.Common.Type             as T
import qualified Icicle.Common.Exp           as CE

import qualified Icicle.Core                    as C
import qualified Icicle.Core.Exp.Combinators    as CE

import           Icicle.Source.Query
import           Icicle.Source.ToCore.Base
import           Icicle.Source.ToCore.Context
import           Icicle.Source.ToCore.Exp
import           Icicle.Source.ToCore.Prim
import           Icicle.Source.Type

import           P

import           Control.Monad.Trans.Class
import           Data.List                      (zip, replicate)
import           Data.Hashable                  (Hashable)
import qualified Data.Map                       as Map


data ConvertFoldResult n
 = ConvertFoldResult
 { foldKons    :: C.Exp () n -- a -> b -> a
 , foldZero    :: C.Exp () n -- a
 , mapExtract  :: C.Exp () n -- a -> c
 , typeFold    :: T.ValType  -- a
 , typeExtract :: T.ValType  -- c
 } deriving (Eq, Ord, Show)


-- | Convert the body of a group by (or other query) into a fold:
--
-- The fold is described by:
--  Konstrukt : a -> b -> a
--  Zero      : a
--  Xtract    : a -> c
--
-- The extract is used for any postprocessing that can only be done on the
-- final result of the accumulator.
--
-- So for example, a sum would be
--  K = (+)
--  Z = 0
--  X = id
--
-- but if we wanted mean, we would store a pair of values in the accumulator,
-- the sum and the count, and then the extract would divide the two:
--  K = (\(s,c) v   -> (s + v, c + 1))
--  Z =                (0, 0)
--  X = (\(s,c)     -> s / c)
--
--
-- Not all subqueries are supported:
--  windows cannot be inside windows/groups/latests
--
--
convertFold
        :: (Hashable n, Eq n)
        => Query (Annot a n) n
        -> ConvertM a n (ConvertFoldResult n)
convertFold q
 = case contexts q of
    -- No contexts, just an expression
    []
     -- Nested query; recurse
     | Nested _ qq <- final q
     -> convertFold qq

     -- Primitive application
     | Just (p, Annot { annAnnot = ann, annResult = retty }, args) <- takePrimApps $ final q
     -- Non-aggregate primitive operations such as (+) or (/) are a bit more involved:
     -- we convert the arguments to folds,
     -- then store the accumulator as nested pairs of arguments
     -- then, for the extract we destruct the pairs and apply the operator normally.
      -> do -- Convert all arguments
            -- (create a query out of the expression,
            --  just because there is no separate convertFoldX function)
            res <- mapM (convertFold . Query []) args
            retty' <- convertValType' retty

            let ts  = fmap typeFold         res
            -- Create pairs for zeros
            (zz, tt) <- pairConstruct (fmap foldZero res) ts

            -- For extraction:
            --  destruct the pairs,
            --  recursively extract the arguments,
            --  apply the primitive
            let cp ns
                    = convertPrim p ann retty
                        ((fmap (uncurry CE.xApp) (fmap mapExtract res `zip` ns)) `zip` fmap (annResult . annotOfExp) args)
            xx       <- pairDestruct cp ts

            -- For konstrukt, we need to destruct the pairs, apply the sub-ks,
            -- then box it up again in pairs.
            let applyKs ns = fst <$> pairConstruct (fmap (uncurry CE.xApp) (fmap foldKons res `zip` ns)) ts
            kk       <- pairDestruct applyKs ts

            return $ ConvertFoldResult kk zz xx tt retty'

     -- Variable lookup.
     | Var (Annot { annAnnot = ann, annResult = retty }) v <- final q
      -> do bound <- convertFreshenLookupMaybe v
            fs <- featureContextVariables <$> convertFeatures
            -- Check if it is a scalar variable or postcomputation
            case bound of
             Just v'
              | TemporalityElement <- getTemporalityOrPure retty
              -> do retty' <- convertValType' retty
                    i <- idFun retty'
                    n'v <- lift fresh
                    let k = CE.xLam n'v retty' $ CE.xVar v'
                    let err = CE.xValue retty' $ T.defaultOfType retty'
                    return $ ConvertFoldResult k err i retty' retty'

             -- For aggregate variables, the actual folding doesn't matter:
             -- we can just return const unit for the fold part,
             -- and at extract return the variable's value
              | otherwise
              -> do n'x <- lift fresh
                    retty' <- convertValType' retty
                    let ut    = T.UnitT
                    let unit = CE.xValue ut VUnit

                    let k    = CE.xLam n'x ut $ unit
                    let z    = unit
                    let x    = CE.xLam n'x ut $ CE.xVar $ v'

                    return $ ConvertFoldResult k z x ut retty'


             -- Otherwise it must be a feature
             _
              | Just fv <- Map.lookup v fs
              -> do -- Creating a fold from a scalar variable is strange, since
                    -- the scalar variable is only available inside each iteration.
                    -- For the konstrukt, we just return the current value.
                    -- For zero, we have no value yet - we must throw an exception.
                    -- This is bad, but is not a problem in practice since scalar variables
                    -- can only be used inside each iteration.
                    -- The exception value won't end up being used.
                    --
                    -- Extract, after the fold is finished, is just identity.
                    -- Const Unit would work too, since the extracted value should
                    -- never be used for the same reason the zero is not used.

                    retty' <- convertValType' retty
                    i <- idFun retty'
                    n'v <- lift fresh
                    inp <- convertInputName
                    let k = CE.xLam n'v retty' $ featureVariableExp fv $ CE.xVar inp
                    let err = CE.xValue retty' $ T.defaultOfType retty'
                    return $ ConvertFoldResult k err i retty' retty'

              | otherwise
              -> convertError $ ConvertErrorExpNoSuchVariable ann v

     | Case (Annot { annAnnot = ann, annResult = retty }) scrut pats <- final q
      -> do -- Case expressions are very similar to primops.
            -- We know that the scrutinee and the patterns are all aggregates.
            -- Elements are handled elsewhere.
            let args = (PatDefault, scrut) : pats
            let goPat (p,alt)
                    = (,) <$> convertCaseFreshenPat p <*> convertFold (Query [] alt)
            args'  <- mapM goPat args
            let pats'= drop 1 $ fmap fst args'
            let res = fmap snd args'

            retty' <- convertValType' retty
            scrutT <- convertValType' $ annResult $ annotOfExp scrut

            let ts  = fmap (typeFold) res
            -- Create pairs for zeros
            (zz, tt) <- pairConstruct (fmap foldZero res) ts

            -- For extraction:
            --  reconstruct the case
            --  and use convertExp
            let cp ns
                    = case fmap (uncurry CE.xApp) (fmap mapExtract res `zip` ns) of
                        (s:alts)
                         -> convertCase (final q) s (pats' `zip` alts) scrutT retty'
                        _
                         -> convertError $ ConvertErrorBadCaseNoDefault ann (final q)
            xx       <- pairDestruct cp ts

            -- For konstrukt, we need to destruct the pairs, apply the sub-ks,
            -- then box it up again in pairs.
            let applyKs ns = fst <$> pairConstruct (fmap (uncurry CE.xApp) (fmap foldKons res `zip` ns)) ts
            kk       <- pairDestruct applyKs ts

            return $ ConvertFoldResult kk zz xx tt retty'


     -- It must be a non-primitive application
     | otherwise
      -> convertError $ ConvertErrorExpApplicationOfNonPrimitive (annAnnot $ annotOfExp $ final q) (final q)

    -- For filter, you convert the subquery as normal,
    -- then only apply the subquery's "k" when the filter predicate is true.
    --
    -- Note that this has different "history semantics" to the normal filter.
    (Filter _ e : _)
     -> do  res <- convertFold q'
            e'         <- convertExp  e
            prev       <- lift fresh
            let tt'    = typeFold res
            let prev'  = CE.xVar prev
            let k' = CE.xLam prev tt'
                   ( CE.xPrim (C.PrimFold C.PrimFoldBool tt')
                     CE.@~ (foldKons res CE.@~ prev') CE.@~ prev' CE.@~ e' )
            return (res { foldKons = k' })

    (Latest _ i : _)
     | case getTemporalityOrPure $ annResult $ annotOfQuery q' of
        TemporalityElement  -> True
        TemporalityPure     -> True
        _                   -> False
     -> do n'acc <- lift fresh
           n'buf <- lift fresh

           res       <- convertExpQ q'
           t'e       <- convertValType' $ annResult $ annotOfQuery q'
           let t'arr  = T.ArrayT t'e
           let t'buf  = T.BufT i t'e

           factid    <- convertFactIdName

           let kons  = CE.xLam n'acc t'buf
                     ( CE.pushBuf i t'e
                         CE.@~ CE.xVar n'acc
                         CE.@~ CE.xVar factid
                         CE.@~ res )
           let zero  = CE.emptyBuf i t'e

           let x'    = CE.xLam n'buf t'buf
                     ( CE.readBuf i t'e CE.@~ CE.xVar n'buf )

           return $ ConvertFoldResult kons zero x' t'buf t'arr

     | otherwise
     -> do n'arr <- lift fresh
           n'acc <- lift fresh
           n'buf <- lift fresh
           n'e   <- lift fresh
           n'x   <- lift fresh
           n'a   <- lift fresh

           inp       <- convertInputName
           inpT      <- convertInputType
           let t'e    = inpT
           let t'buf  = T.BufT i t'e

           res       <- convertWithInputName n'e $ convertFold q'
           let t'x    = typeFold res
           let t'r    = typeExtract res

           factid    <- convertFactIdName

           let kons  = CE.xLam n'acc t'buf
                     ( CE.pushBuf i t'e
                         CE.@~ CE.xVar n'acc
                         CE.@~ CE.xVar factid
                         CE.@~ CE.xVar inp )
           let zero  = CE.emptyBuf i t'e

           -- Flip the res fold arguments so it can be use with Array_fold
           let k'    = CE.xLam n'x t'x
                     $ CE.xLam n'e t'e
                     $ beta
                     ( foldKons res CE.@~ CE.xVar n'x )

           -- Apply the res fold
           let x'    = CE.xLet n'arr
                     ( CE.readBuf i t'e CE.@~ CE.xVar n'buf )
                     ( CE.xPrim (C.PrimFold (C.PrimFoldArray t'e) t'x)
                         CE.@~ k'
                         CE.@~ beta (foldZero res)
                         CE.@~ CE.xVar n'arr )

           -- Apply the res extract
           let xtra  = CE.xLam n'buf t'buf
                     $ CE.xLet n'a x'
                     ( mapExtract res CE.@~ CE.xVar n'a )

           return $ ConvertFoldResult kons zero xtra t'buf t'r

    -- Fold over an existing group.
    (GroupBy (Annot { annAnnot = ann, annResult = retty }) k : _)
     -> do -- Convert the rest of the query into a fold.
           res     <- convertFold q'

           -- Construct the map.
           n'map     <- lift fresh
           k'        <- convertExp k
           t'k       <- convertValType' $ annResult $ annotOfExp k

           let t'fold  = typeFold res
           let t'xtra  = typeExtract res
           let t'map   = T.MapT t'k t'fold

           let zero = CE.xValue t'map $ VMap Map.empty
           let kons = CE.xLam n'map t'map
                    $ CE.makeApps () (primInsUpd t'k t'fold)
                    [ foldKons res
                    , foldKons res `CE.xApp` foldZero res
                    , k'
                    , CE.xVar n'map ]

           -- Fold over the map, apply the extraction on each value.
           n'r   <- lift fresh
           n'r'  <- lift fresh
           n'k   <- lift fresh
           n'k'  <- lift fresh
           n'x   <- lift fresh
           n'x'  <- lift fresh
           n'x'r <- lift fresh
           n'err <- lift fresh

           (t'kr, t'xr) <- getGroupByMapType ann retty

           let isPossibly
                 = PossibilityPossibly == getPossibilityOrDefinitely retty
           let (t'sum, x'sumzero)
                 = groupMapSum isPossibly t'kr t'xr
           let unwrapSum' chk
                 = unwrapSum chk t'sum n'err
           let rewrapSum'
                 = rewrapSum isPossibly t'sum

           let extract n
                 = mapExtract res CE.@~ CE.xVar n
           let ins
                 = CE.xLam n'r t'sum
                 $ CE.xLam n'k t'k
                 $ CE.xLam n'x t'fold
                 $ unwrapSum'  isPossibly                         (CE.xVar n'r) n'r' t'sum
                 $ unwrapSum' (isAnnotPossibly $ annotOfExp   k)  (CE.xVar n'k) n'k' t'k
                 $ unwrapSum' (isAnnotPossibly $ annotOfQuery q') (extract n'x) n'x' t'xtra
                 $ rewrapSum'
                 $ CE.makeApps () (primInsUpd t'kr t'xr)
                 [ CE.xLam n'x'r t'xr $ CE.xVar n'x'r
                 , CE.xVar n'x'
                 , CE.xVar n'k'
                 , CE.xVar n'r' ]

           let xtra
                = CE.xPrim (C.PrimFold (C.PrimFoldMap t'k t'fold) t'sum)
                  CE.@~ ins
                  CE.@~ x'sumzero

           return $ ConvertFoldResult kons zero xtra t'map t'sum

    -- Distinct inside an existing group.
    (Distinct _ k : _)
     -> do -- Convert the rest of the query into a fold.
           res     <- convertFold q'

           -- Construct the map.
           n'pair <- lift fresh
           n'_    <- lift fresh
           n'__   <- lift fresh

           k'     <- convertExp k
           t'k    <- convertValType' $ annResult $ annotOfExp k

           let t'fold  = typeFold res
           let t'xtra  = typeExtract res
           let t'map   = T.MapT t'k T.UnitT
           let t'pair  = T.PairT t'map t'fold

           let x'fst
                 = CE.xApp $ CE.xPrim $ C.PrimMinimal $ Min.PrimPair $ Min.PrimPairFst t'map t'fold
           let x'snd
                 = CE.xApp $ CE.xPrim $ C.PrimMinimal $ Min.PrimPair $ Min.PrimPairSnd t'map t'fold
           let x'pair x y
                 = (CE.xPrim $ C.PrimMinimal $ Min.PrimConst $ Min.PrimConstPair t'map t'fold)
                    CE.@~ x CE.@~ y
           let x'unit
                 = CE.xValue T.UnitT VUnit

           let zero
                 = x'pair (CE.emptyMap t'k T.UnitT) (foldZero res)

           let ins
                 = CE.makeApps () (primInsUpd t'k T.UnitT)
                 [ CE.xLam n'_ T.UnitT x'unit
                 , x'unit
                 , k'
                 , x'fst (CE.xVar n'pair)]
           let upd
                 = x'pair ins (foldKons res CE.@~ x'snd (CE.xVar n'pair) )
           let kons
                 = CE.xLam n'pair t'pair
                 ( CE.xPrim (C.PrimFold (C.PrimFoldOption T.UnitT) t'pair)
                     CE.@~ CE.xLam n'__ T.UnitT (CE.xVar n'pair)
                     CE.@~ CE.xLam n'__ T.UnitT upd
                     CE.@~ ( CE.xPrim (C.PrimMap (C.PrimMapLookup t'k T.UnitT))
                               CE.@~ x'fst (CE.xVar n'pair)
                               CE.@~ k' ) )

           -- Fold over the map
           let xtra
                = CE.xLam n'pair t'pair
                ( mapExtract res CE.@~ x'snd (CE.xVar n'pair))

           return $ ConvertFoldResult kons zero xtra t'pair t'xtra

    (GroupFold (Annot { annAnnot = ann }) _ _ _ : _)
     -> errNotAllowed ann
    (Windowed (Annot { annAnnot = ann }) _ _ : _)
     -> errNotAllowed ann

    (Let _ b def : _)
     | TemporalityPure  <- getTemporalityOrPure $ annResult $ annotOfExp def
     -> do  def' <- convertExp def
            n'   <- lift fresh
            t' <- convertValType' $ annResult $ annotOfExp def
            let res = ConvertFoldResult (CE.xLam n' t' def') def' (CE.xLam n' t' def') t' t'
            convertAsLet b res

     | TemporalityElement  <- getTemporalityOrPure $ annResult $ annotOfExp def
     -> do  def' <- convertExp def
            n'   <- lift fresh
            t' <- convertValType' $ annResult $ annotOfExp def
            let err = CE.xValue t' $ T.defaultOfType t'
            let res = ConvertFoldResult (CE.xLam n' t' def') err (CE.xLam n' t' $ CE.xVar n') t' t'
            convertAsLet b res

     | otherwise
     -> do  resb <- convertFold (Query [] def)
            convertAsLet b resb

    (LetFold (Annot { annAnnot = ann }) Fold{ foldType = FoldTypeFoldl1 } : _)
     -> convertError $ ConvertErrorImpossibleFold1 ann


    (LetFold _ f@Fold{ foldType = FoldTypeFoldl } : _)
     -> do  -- Type helpers
            tU <- convertValType' $ annResult $ annotOfExp $ foldWork f


            z   <- convertExp (foldInit f)
            -- Current accumulator is only available in worker
            (n'a,k) <- convertContext
                     $ do n'a <- convertFreshenAdd $ foldBind f
                          k   <- convertExp (foldWork f)
                          return (n'a, k)

            let k' = CE.xLam n'a tU k

            x' <- idFun tU

            let res = ConvertFoldResult k' z x' tU tU
            convertAsLet (foldBind f) res



 where
  q' = q { contexts = drop 1 $ contexts q }

  errNotAllowed ann
   = convertError $ ConvertErrorContextNotAllowedInGroupBy ann q

  -- Perform beta reduction, just to simplify the output a tiny bit.
  beta = Beta.betaToLets ()
       . Beta.beta Beta.isSimpleValue

  -- Construct an identity function
  idFun tt = lift fresh >>= \n -> return (CE.xLam n tt (CE.xVar n))

  nonunits = filter (/=T.UnitT)
  -- Create nested pair type for storing the result of subexpressions
  pairTypes ts
   = case nonunits ts of
      (t:ts') -> foldl T.PairT t ts'
      []      -> T.UnitT

  -- Create nested pairs of arguments
  pairConstruct xs ts
   = let xts = filter ((/=T.UnitT).snd) $ zip xs ts
     in  return
       $ case xts of
          ((x,t):xts')
           -> foldl
               (\(xa,ta) (x',t')
                -> ( CE.xPrim
                        (C.PrimMinimal $ Min.PrimConst $ Min.PrimConstPair ta t')
                        CE.@~ xa CE.@~ x'
                   , T.PairT ta t')) ( x, t ) xts'
          []
           -> (CE.xValue T.UnitT VUnit, T.UnitT)

  -- Destruct nested pairs.
  -- Call "f" with expression for each element of the pair.
  pairDestruct f ts
   | [] <- nonunits ts
   = do n1 <- lift fresh
        f' <- f (replicate (length ts) (CE.xValue T.UnitT VUnit))
        return $ CE.xLam n1 T.UnitT f'

  pairDestruct f ts
   = pairDestruct' f ts

  pairDestruct' f []
   = f []

  pairDestruct' f (T.UnitT:ts)
   = do let f' xs = f (CE.xValue T.UnitT VUnit : xs)
        pairDestruct' f' ts

  pairDestruct' f (t:ts)
   | [] <- nonunits ts
   = do n1 <- lift fresh
        let f' xs = f (CE.xVar n1 : xs)
        rest <- pairDestruct' f' ts
        let xx = CE.xLam n1 t rest
        return xx

  pairDestruct' f (t:ts)
   = do nl <- lift fresh
        n1 <- lift fresh
        let f' xs = f (CE.xVar n1 : xs)
        let tr    = pairTypes ts

        rest <- pairDestruct' f' ts

        let xfst = CE.xPrim (C.PrimMinimal $ Min.PrimPair $ Min.PrimPairFst t tr) CE.@~ CE.xVar nl
        let xsnd = CE.xPrim (C.PrimMinimal $ Min.PrimPair $ Min.PrimPairSnd t tr) CE.@~ CE.xVar nl

        let xx = CE.xLam nl (T.PairT t tr)
               $ CE.xLet n1 xfst
               ( rest CE.@~ xsnd )

        return xx


  convertAsLet b resb
   = convertContext
   $    do  b'     <- convertFreshenAdd b
            resq   <- convertFold q'
            let tb' = typeFold resb
            let tq' = typeFold resq
            let tpair = pairTypes [tb', tq']

            let fk' [xa,xb]
                    = do (kp',_) <- pairConstruct [CE.xVar b', foldKons resq CE.@~ xb ] [tb', tq']
                         return $ CE.xLet b' (foldKons resb CE.@~ xa) kp'
                fk' s
                    = fk' s
            k' <- pairDestruct fk' [tb', tq']

            (zp',_) <- pairConstruct [CE.xVar b', foldZero resq ] [tb', tq']
            let z'  = CE.xLet b' (foldZero resb) zp'


            let cp [xa,xb]
                    = return
                    $ CE.xLet b' (mapExtract resb CE.@~ xa)
                                 (mapExtract resq CE.@~ xb)
                cp  s
                    = cp  s
            x' <- pairDestruct cp [tb', tq']

            return $ ConvertFoldResult k' z' x' tpair (typeExtract resq)

  convertValType'   = convertValType (annAnnot $ annotOfQuery q)
  getGroupByMapType = groupMapType  convertValType'

  primInsUpd a b = CE.xPrim $ C.PrimMap $ C.PrimMapInsertOrUpdate a b


-- | Group bys can live in either Aggregate or Group universe.
--   Because Core is explicitly typed, we need to pull out the key type and value type.
groupMapType :: (Type n -> ConvertM a n T.ValType)
             -> a
             -> Type n
             -> ConvertM a n (T.ValType, T.ValType)
groupMapType convertValType' ann ty
 | (_,_,t') <- decomposeT ty
 , (GroupT tk tv) <- t'
 = (,) <$> convertValType' tk <*> convertValType' tv
 | (_,_,t') <- decomposeT ty
 , (SumT ErrorT (GroupT tk tv)) <- t'
 = (,) <$> convertValType' tk <*> convertValType' tv
 | otherwise
 = convertError $ ConvertErrorGroupByHasNonGroupResult ann ty

-- | Get the key and value type of a group inside a group-fold.
groupFoldType :: (Type n -> ConvertM a n T.ValType)
              -> a
              -> Exp (Annot a n) n
              -> ConvertM a n (T.ValType, T.ValType)
groupFoldType convertValType' a e
 = do t <- convertValType' $ annResult $ annotOfExp e
      case t of
       T.MapT tk tv -> return (tk, tv)
       _            -> convertError $ ConvertErrorGroupFoldNotOnGroup a e

groupMapSum :: Bool -> T.ValType -> T.ValType -> (T.ValType, C.Exp () n)
groupMapSum isPossibly tk tx
  = let sumt
          | isPossibly
          = T.SumT T.ErrorT $ T.MapT tk tx
          | otherwise
          = T.MapT tk tx
        emptyResult
          | isPossibly
          = CE.xValue sumt $ VRight $ VMap Map.empty
          | otherwise
          = CE.xValue sumt $ VMap Map.empty
    in (sumt, emptyResult)
