{-# LANGUAGE RecordWildCards #-}
module Machine where

import Control.Arrow

import Rules
import Labels
import Instructions
import Primitives

data State = State { imem  :: IMem
                   , mem   :: Memory
                   , stack :: Stack
                   , regs  :: RegSet
                   , pc    :: PtrAtom } 
           deriving (Eq, Show, Read)

-- Execution - for now "correct"
-- I tried to get all the changing parts inside a let for easier tweaking later
exec' :: RuleTable -> State -> Instr -> Maybe (Trace, State)
exec' t s@(State {..}) instruction = do
  let (PAtm addrPc lpc) = pc 
  case instruction of 
    Lab r1 r2 -> do
      -- TRUE, BOT, LabPC
      Atom _ k <- readR r1 regs
      (Just rlab, rlpc) <- runTMU t LAB [] lpc
      let result = VLab k
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r2 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    PcLab r1 -> do
      -- TRUE, BOT, LabPC
      (Just rlab, rlpc) <- runTMU t PCLAB [] lpc
      let result = VLab $ pcLab pc
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r1 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    MLab r1 r2 -> do
      -- TRUE, k, LabPC
      Atom (VPtr ptr) k <- readR r1 regs
      c <- mlab mem ptr
      (Just rlab, rlpc) <- runTMU t MLAB [k,c] lpc
      let result = VLab c
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r2 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    FlowsTo r1 r2 r3 -> do
      -- True, Join k1 k2, LabPC
      Atom (VLab l1) k1 <- readR r1 regs
      Atom (VLab l2) k2 <- readR r2 regs
      (Just rlab, rlpc) <- runTMU t FLOWSTO [k1,k2] lpc
      let result = VInt $ flows l1 l2 
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r3 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    LJoin r1 r2 r3 -> do
      -- True, Join k1 k2, LabPC                     
      Atom (VLab l1) k1 <- readR r1 regs
      Atom (VLab l2) k2 <- readR r2 regs
      (Just rlab, rlpc) <- runTMU t LJOIN [k1,k2] lpc
      let result = VLab $ l1 `lub` l2 
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r3 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    PutBot r1 -> do
      -- True, BOT, LabPC
      (Just rlab, rlpc) <- runTMU t PUTBOT [] lpc
      let result = VLab bot 
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r1 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    BCall r1 r2 r3 -> do
      -- True, Join k LabPC, Join l LabPC
      Atom (VInt addr) l <- readR r1 regs
      Atom (VLab b)    k <- readR r2 regs
      (Just rlab, rlpc) <- runTMU t BCALL [l,k] lpc
      let stack' = Stack $  (StkElt (PAtm (addrPc + 1) rlab, b, regs, r3)) 
                    : unStack stack
          pc'    = PAtm addr rlpc
      return ([], s{stack = stack', pc = pc'})
    BRet -> do
      -- LE (Join r LabPC) (Join b lpc'), b, lpc'
      case unStack stack of 
        (StkElt (PAtm addrPc' lpc', b, saved, retR) : stack') -> do
          Atom a r <- readR retR regs
          (Just rlab, rlpc) <- runTMU t BRET [r,b,lpc'] lpc
          let result = a
              pc'    = PAtm addrPc' rlpc
          regs' <- writeR retR (Atom result rlab) saved
          return ([], s{stack = Stack stack', pc = pc', regs = regs'})
        _ -> Nothing
    Alloc r1 r2 r3 -> do
      -- True, Join Lab1 Lab2, LabPC
      Atom (VInt i) k  <- readR r1 regs
      Atom (VLab l) k' <- readR r2 regs
      (Just rlab, rlpc) <- runTMU t ALLOC [k,k',l] lpc
      let stamp  = k `lub` k' `lub` lpc
      (block, mem') <- alloc i l stamp (Atom (VInt 0) bot) mem
      let result = VPtr $ Ptr block 0
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r3 (Atom result rlab) regs
      return ([], s{mem = mem', regs = regs', pc = pc'})
    Load r1 r2 -> do
      -- True, l, Join LabPc (Join k c)
      Atom (VPtr p) k <- readR r1 regs
      Atom v l <- load mem p
      c <- mlab mem p
      (Just rlab, rlpc) <- runTMU t LOAD [k,c,l] lpc
      let result = v
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r2 (Atom v rlab) regs
      return ([], s{regs = regs', pc = pc'})
    Store r1 r2 -> do
      -- LE (Join k LabPC) c, l, LabPC
      Atom (VPtr p) k <- readR r1 regs
      Atom v l <- readR r2 regs
      c <- mlab mem p
      (Just rlab, rlpc) <- runTMU t STORE [k,c,l] lpc
      let result = v
          pc'    = PAtm (addrPc + 1) rlpc
      mem' <- store mem p (Atom v rlab)
      return ([], s{mem = mem', pc = pc'})
    Jump r1 -> do
      -- True, __ , Join LabPC l
      Atom (VInt addr) l <- readR r1 regs
      (_, rlpc) <- runTMU t JUMP [l] lpc
      let pc'    = PAtm addr rlpc
      return ([], s{pc = pc'})
    Bnz n r1 -> do
      -- True, __, Join k LabPC
      Atom (VInt m) k <- readR r1 regs
      (_, rlpc) <- runTMU t BNZ [k] lpc
      let addr' = if m == 0 then addrPc + 1 else addrPc + n
          pc'    = PAtm addr' rlpc
      return ([], s{pc = pc'})
    PSetOff r1 r2 r3 -> do
      -- True, Join k1 k2, LabPC
      Atom (VPtr (Ptr fp addr)) k1 <- readR r1 regs
      Atom (VInt n) k2 <- readR r2 regs
      (Just rlab, rlpc) <- runTMU t PSETOFF [k1,k2] lpc
      let result = VPtr (Ptr fp n)
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r3 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    Output r1 -> do
      -- True, Join k LabPC, LabPC
      Atom (VInt n) k <- readR r1 regs
      (Just rlab, rlpc) <- runTMU t OUTPUT [k] lpc
      let result = VInt n
          pc'    = PAtm (addrPc + 1) rlpc
      return ([(result, rlab)], s{pc = pc'})
    Put x r1 -> do
      -- True, BOT, LabPC
      (Just rlab, rlpc) <- runTMU t PUT [] lpc
      let result = VInt x
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r1 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    BinOp o r1 r2 r3 -> do
      -- True, Join l1 l2, LabPC
      Atom (VInt n1) l1 <- readR r1 regs
      Atom (VInt n2) l2 <- readR r2 regs 
      (Just rlab, rlpc) <- runTMU t BINOP [l1,l2] lpc
      let result = VInt $ evalBinop o n1 n2 
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r3 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    Noop -> do
      -- True, __, LabPC
      (_, rlpc) <- runTMU t NOOP [] lpc
      let pc'    = PAtm (addrPc + 1) rlpc
      return ([], s{pc = pc'})
    MSize r1 r2 -> do
      -- True, c, Join LabPC k
      Atom (VPtr p) k <- readR r1 regs
      c <- mlab mem p
      n <- msize mem p 
      (Just rlab, rlpc) <- runTMU t MSIZE [k,c] lpc
      let result = VInt n
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r2 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    PGetOff r1 r2 -> do
      -- True, k, LabPC
      Atom (VPtr (Ptr fp addr')) k <- readR r1 regs
      (Just rlab, rlpc) <- runTMU t PGETOFF [k] lpc
      let result = VInt addr'
          pc'    = PAtm (addrPc + 1) rlpc
      regs' <- writeR r2 (Atom result rlab) regs
      return ([], s{regs = regs', pc = pc'})
    Halt -> Nothing

exec :: RuleTable -> State -> Maybe (Trace, State)
exec r s@State{..} = do 
  instruction <- instrLookup imem pc
  exec' r s instruction

execN :: Int -> RuleTable -> State -> (Trace, [State])
execN 0 t s = ([], [s])
execN n t s = case exec t s of
                Just (tr, s') -> ((tr ++) *** (s :)) $ execN (n-1) t s'
                Nothing -> ([], [s])

-- All Values should be Ints
observe :: Label -> Trace -> [Value]
observe obs [] = []
observe obs ((v,l'):t') 
    | isLow l' obs = v : observe obs t'
    | otherwise  = observe obs t'

observeComp :: [Value] -> [Value] -> Bool
observeComp (v1:t1) (v2:t2) = v1 == v2 && observeComp t1 t2
observeComp _ _ = True
    
    