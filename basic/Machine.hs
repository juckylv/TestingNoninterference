{-# LANGUAGE FlexibleContexts, UndecidableInstances, RecordWildCards,
    TupleSections, MonoLocalBinds #-}

module Machine where

import Test.QuickCheck.Gen
import Test.QuickCheck
import Control.Monad
import Control.Applicative
import Text.PrettyPrint hiding (int)
import Data.Function
import Data.List ( find, groupBy)

import Util
import Pretty
import GenericMachine
import Trace
import LaTeX

import Labels
import Flags
import Observable
import Instr

-- import Debug.Trace

{---------------------------- The abstract machine ----------------------------}

-- One complicated feature of the abstract machine is that all of its
-- addresses are "offset" -- i.e., its data and instruction memories
-- each have some number of inaccessible dummy locations at the
-- beginning.  For example, if the abstract machine has memory of the
-- form [a,b,c,...], then when concretized, it will gain six words at
-- the front for the TMU cache: [instr, tag1, tag2, tagPC, tagRes,
-- tagResPC, a, b, c, ...].  Similarly, the instruction memory grows
-- by the size of the whole tmmRoutine.  Thus, in general, we need to
-- subtract of the tmuCacheSize from every data address before
-- indexing, and we subtract off the length of the tmmRoutine from
-- every instruction address before indexing.

-- An alternative definition astk :: [Labeled AStkElt] where
--     data AStkElt = AData Int
--                  | ARet  Int  -- address to return to
--                          Int  -- how many stack entries to return
--      deriving (Eq, Read, Show)  
-- 
-- but this is not nice because it means that a stack containing a
-- (high) return address can be equivalent to a stack containing data
-- in the same slot.  Such a stack cannot be generated by a program
-- starting from an empty stack.

data AStkElt = AData Atom
             | ARet  (Labeled (Int,Bool))  -- (address to return to,
                                           -- whether to return a value or not)
  deriving (Eq, Read)

instance Show AStkElt where
  show (AData a) = show a
  show (ARet x) = "ARet " ++ show x

instance LaTeX AStkElt where
  toLaTeX (AData d) = toLaTeX d
  toLaTeX (ARet (Labeled l (r,b))) =
    "\\HSret{" ++ toLaTeX r ++ "}{" ++ toLaTeX b ++ "}{" ++ toLaTeX l ++ "}"

data AS = AS { amem  :: [Atom],        -- starting at minaddr
               aimem :: [Instr],       -- starting after alloc routine
               astk  :: [AStkElt],     -- same interpretation as in CS
               apc   :: Labeled Int }  -- ditto
  deriving (Eq, Read)

isAData :: AStkElt -> Bool
isAData (AData _) = True
isAData _         = False

isARet :: AStkElt -> Bool
isARet = not . isAData

astkData :: AStkElt -> Atom
astkData (AData d) = d
astkData _         = error "astkData received an ARet"

astkValue :: AStkElt -> Int
astkValue (AData d) = value d
astkValue _         = error "astkValue received an ARet"

astkRetPC :: AStkElt -> Labeled Int
astkRetPC (ARet p) = fmap fst p
astkRetPC _        = error "astkRetPC received an AData"

astkReturns :: AStkElt -> Bool
astkReturns (ARet p) = snd $ value p
astkReturns _        = error "astkRetItems received an AData"

astkLab :: AStkElt -> Label
astkLab (AData d) = lab d
astkLab (ARet p)  = lab p

-- CH: I don't think this class belongs here
instance Flaggy DynFlags => Observable AStkElt where
  e ~~~ e' =
    case stk_elt_equiv getFlags of
      TagOnTop -> -- correct version
        case (e, e') of
          (AData d, AData d') -> d ~~~ d'
          (ARet p , ARet p' ) -> p ~~~ p'
          (_      , _       ) -> False
      LabelOnTop -> -- incorrect version
        case (astkLab e, astkLab e') of
          (L, L) -> e == e'
          (H, H) -> True
          (_, _) -> False -- assumming this bug won't be
                          -- mixed with atom_equiv bugs
  
  vary _ = error "Observable AStkElt implements no vary"
{- dead code:
  vary (AData d) = fmap AData $ vary d
  vary (ARet (Labeled H (raddr, _)))  = do
    i <- choose (-10,10)
    bret <- arbitrary
    return $ ARet $ Labeled H $ (raddr+i,bret)
  vary (ARet (Labeled L p)) = return $ ARet $ Labeled L p
-}
  
  shrinkV (Variation (AData d) (AData d'))
     = map (fmap AData) (shrinkV (Variation d d'))
  shrinkV (Variation (ARet p) (ARet p'))
     = map (fmap ARet) (shrinkV (Variation p p'))
  shrinkV (v@(Variation x1 x2)) -- incorrect version
    | stk_elt_equiv getFlags == LabelOnTop
      && astkLab x1 == H && astkLab x2 == H
    = [Variation x1 x1, Variation x2 x2]
      ++ [Variation x1' x2 | x1' <- shrinkStkEltKeepLabel x1]
      ++ [Variation x1 x2' | x2' <- shrinkStkEltKeepLabel x2]
    | otherwise = errorShrinkV "AStkElt" v
   where shrinkStkEltKeepLabel (AData (Labeled l x)) = AData . Labeled l <$> shrink x
         shrinkStkEltKeepLabel (ARet (Labeled l x)) = ARet . Labeled l <$> shrink x

instance Flaggy DynFlags => Arbitrary AStkElt where
  arbitrary
    = frequency $ [ (4,liftM AData (labeled int)) ] ++
                  [ (1,liftM ARet  (labeled ret_arbitrary)) | cally ] 
    where ret_arbitrary =
            liftM2 (,) (if smart_ints getFlags
                        then choose (0, 20)
                        else int) arbitrary
          cally :: Flaggy DynFlags => Bool 
          cally         = callsAllowed (gen_instrs getFlags)
  shrink (AData i) = map AData $ shrink i
  shrink (ARet p) = AData (fmap fst p) : map ARet (shrink p) 

-- TODO (a bit later): refine the machine so that the call stack is
-- separate from the data stack and the return instruction (which will
-- now be a separate thing from JUMP) lowers the PC tag.

instance Pretty AS where
  pretty AS{..} =
    text "AS" <+> record
      [ field "amem"  $ l amem
      , field "aimem" $ l aimem
      , field "astk"  $ l astk
      , field "apc"   $ text $ show apc ]
    where
      l :: Show a => [a] -> Doc
      l xs = list $ map (text . show) xs
      field s d = sep [ text s <+> text "=", nest 2 d ]

instance Show AS where
  show = show . pretty

instance Flaggy DynFlags => Machine AS where
  isStep as as' = isWF as && as' == astepFn as
  step = defaultStep "TMUAbstract.AS" $ return . astepFn
  wf = wf_impl

wf_impl :: Flaggy DynFlags => AS -> WFCheck
wf_impl as = wfChecks checks
  where
    checks :: Flaggy DynFlags => [WFCheck]
    checks   = pc_check : instrChecks instr as
    pc_check :: Flaggy DynFlags => WFCheck
    pc_check = iptr `isIndex`
                  aimem as `orElse` "pc out of range"

    iptr :: Flaggy DynFlags => Int
    iptr  = value $ apc as
    instr :: Flaggy DynFlags => Instr
    instr = aimem as !! iptr


instrChecks :: Flaggy DynFlags => Instr -> AS -> [WFCheck]
instrChecks is AS{..} = instr_checks is
  where
    instr_checks Noop     = [WF]
    instr_checks Add      = [stackSize 2] 
    instr_checks (Push _) = [WF]
    instr_checks Pop      =
      [ if bugPopPopsReturns
          then -- Includes return addresses!
               length astk >= 1 `orElse` "stack underflow"
          else stackSize 1 ]
    instr_checks Load
      = [ stackSize 1
        , mptr `isIndex` amem `orElse` "load or store out of range"]
    instr_checks Store
      = [ stackSize 2
        , mptr `isIndex` amem `orElse` "load or store out of range"
        , ((not variantDisallowStoreThroughHighPtr) || lab (astkData addr) == L)
               `orElse` "store through high address"
        , (bugAllowWriteDownThroughHighPtr || astkLab addr <= lab (amem!!mptr))
               `orElse` ("sensitive upgrade" ++ if_not_basic "(high address)")
        , (bugAllowWriteDownWithHighPc || lab apc <= lab (amem!!mptr))
               `orElse` ("sensitive upgrade" ++ if_not_basic "(high pc)")
        ]
    instr_checks Jump
      = [ stackSize 1 ]
    instr_checks (Call a r)
      = [ stackSize (a+1) ]
    instr_checks (Return b)
      | Just (ARet (Labeled _ (pc,r))) <- find (not . isAData) astk
      = [ stackSize (if not bugValueOrVoidOnReturn
                     then (if r then 1 else 0) 
                     else (if b then 1 else 0))]
      | otherwise
      = [IF "no return address on stack"]
    instr_checks Halt = [IF ("halt" ++ pcl)]
      where pcl = if gen_instrs getFlags /= InstrsBasic then
                     if lab apc == L then " (low)" else " (high)"
                  else ""

    if_not_basic s = if gen_instrs getFlags /= InstrsBasic then s else ""

    iptr  = value apc
    instr = aimem !! iptr
    stk   = takeWhile isAData astk
    stackSize n = length stk >= n `orElse` "stack underflow"
    ~(addr : ~(val:_)) = stk
    mptr  = astkValue addr
    variantDisallowStoreThroughHighPtr
      = IfcVariantDisallowStoreThroughHighPtr `elem` ifcsem
    bugPopPopsReturns
      = IfcBugPopPopsReturns `elem` ifcsem
    bugAllowWriteDownThroughHighPtr
      = IfcBugAllowWriteDownThroughHighPtr `elem` ifcsem
    bugAllowWriteDownWithHighPc
      = IfcBugAllowWriteDownWithHighPc `elem` ifcsem
    bugValueOrVoidOnReturn
      = IfcBugValueOrVoidOnReturn `elem` ifcsem
    ifcsem = readIfcSemantics getFlags

astepInstr :: Flaggy DynFlags => AS -> Instr -> AS
-- Just check what would hapen to AS if at the PC position we would
-- execute the instruction 
astepInstr as@AS{..} is =
    case is of
    Noop ->
      as{apc = apc + 1}
    Add -> 
      let a:b:astk' = astk
          l = if not bugArithNoTaint
              then lab (astkData a) `lub` lab (astkData b)
              else L
      in as{ astk = AData (Labeled l $ ((+) `on` (value . astkData)) a b) : astk'
           , apc = apc + 1 }
    Push a -> 
      let a' = Labeled (if not bugPushNoTaint
                          then lab a
                          else L)
                       (value a)
      in as{astk = AData a' : astk, apc = apc + 1}
    Pop -> 
      let _:astk' = astk
      in as{astk = astk', apc = apc + 1}
    Load -> 
      let a:astk' = astk
      in as { astk = AData ((if not bugLoadNoTaint
                               then (astkData a `tainting`)
                               else id)
                            (amem !! astkValue a)) : astk'
            , apc = apc + 1 }
    Store ->
      let a:b:astk' = astk
          tainted 
            | bugStoreNoValueTaint = Labeled L (value (astkData b))
            | bugStoreNoPointerTaint && bugStoreNoPcTaint = astkData b
            | bugStoreNoPointerTaint = apc `tainting` astkData b
            | bugStoreNoPcTaint = astkData a `tainting` astkData b
            | otherwise = apc `tainting` astkData a `tainting` astkData b

          oldContents = amem !! astkValue a
          newContents = if variantWriteDownAsNoop
                        -- DD: don't get this one -- could this sanity
                        -- check be turned into a a single "meta-flag"
                        -- that would be checked in instr_checks?  CH:
                        -- no, this check failing doesn't stop the machine
                           && (lab apc `lub` lab (astkData a)
                               > lab oldContents)
                          then oldContents
                          else tainted
      in as{ amem = update (astkValue a) newContents amem
           , astk = astk', apc = apc + 1 }
    Jump ->
      let p:astk' = astk in
      as {astk = astk', apc = 
             case (bugJumpNoRaisePc, bugJumpLowerPc) of
             (False, False) -> apc `tainting` astkData p
             (False, True ) -> astkData p
             (True , False) -> Labeled (lab apc) (value (astkData p))
             (True , True ) -> Labeled L (value (astkData p)) }
    Call a r ->
      as { astk = take a (drop 1 astk) ++ [ARet (fmap (,r) (apc + 1))]
                  ++ drop (a+1) astk
         , apc = if not bugCallNoRaisePc
                 then apc `tainting` astkData (head astk)
                 else astkData (head astk) }
          -- injected/discovered bug:  apc = astkData (head astk)
          -- [Push 0@L,Push 4@L,Call 0 0,{Push 2@H/Push 1@H},Jump]
    Return b ->
      let (ARet (Labeled l (pc,r))):astk' = dropWhile isAData astk
      in as{ astk = map (AData . if not bugReturnNoTaint
                                 then (apc `tainting`) . astkData
                                 else astkData)
                        (take (if not bugValueOrVoidOnReturn
                              then (if r then 1 else 0)
                              else (if b then 1 else 0))
                         astk) ++
                    astk'
           , apc = Labeled l pc }
    
    Halt -> error "astepFn: Impossible: Can't execute Halt."
    
  where
    bugPushNoTaint
      = IfcBugPushNoTaint `elem` ifcsem
    bugArithNoTaint
      = IfcBugArithNoTaint `elem` ifcsem
    bugLoadNoTaint
      = IfcBugLoadNoTaint `elem` ifcsem
    bugStoreNoValueTaint
      = IfcBugStoreNoValueTaint `elem` ifcsem
    bugStoreNoPointerTaint
      = IfcBugStoreNoPointerTaint `elem` ifcsem
    bugStoreNoPcTaint
      = IfcBugStoreNoPcTaint `elem` ifcsem
    bugJumpNoRaisePc
      = IfcBugJumpNoRaisePc `elem` ifcsem
    bugJumpLowerPc
      = IfcBugJumpLowerPc `elem` ifcsem
    bugJumpNZNoRaisePcTaken
      = IfcBugJumpNZNoRaisePcTaken `elem` ifcsem
    bugJumpNZNoRaisePcNotTaken
      = IfcBugJumpNZNoRaisePcNotTaken `elem` ifcsem
    bugReturnNoTaint
      = IfcBugReturnNoTaint `elem` ifcsem
    bugCallNoRaisePc
      = IfcBugCallNoRaisePc `elem` ifcsem
    variantWriteDownAsNoop
      = IfcVariantWriteDownAsNoop `elem` ifcsem
    bugValueOrVoidOnReturn
      = IfcBugValueOrVoidOnReturn `elem` ifcsem

    ifcsem :: Flaggy DynFlags => [IfcSemantics] 
    ifcsem = readIfcSemantics getFlags

    labToInt L = 0
    labToInt H = 1

astepFn :: Flaggy DynFlags => AS -> AS
astepFn as@AS{..} =
  astepInstr as (aimem !! value apc)
  

{----- Properties on the abstract semantics -----}

-- DD: Exercises in Quickcheck...
-- The program is constant along the execution of the abstract machine
prop_prog_const :: Flaggy DynFlags => AS -> Property
prop_prog_const as =
  shrinking shrink (500::Int) $ \n ->
    forAll (traceN as n) $ \(Trace ass) ->
        and (zipWith ( (==) `on` aimem) ass (drop 1 ass))

-- The stack height is constant at program points
-- This does not hold.
prop_stackheight :: Flaggy DynFlags => AS -> Property
prop_stackheight as =
  shrinking shrink (500::Int) $ \n ->
    forAll (traceN as n) $ \(Trace ass) ->
        let pc_lists = groupBy ((==) `on` apc) ass in
        let sh_are_equal ass = and (zipWith ((==) `on` length . astk) 
                                             ass 
                                             (drop 1 ass)) in
        -- assumption: only considering changes of height size that do
        -- not block the semantics
        all isWF ass  ==>
        all sh_are_equal pc_lists
