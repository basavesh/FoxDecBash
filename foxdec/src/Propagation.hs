{-# LANGUAGE PartialTypeSignatures, MultiParamTypeClasses, DeriveGeneric, DefaultSignatures, FlexibleContexts, Strict #-}

module Propagation where

import Base
import Context

import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import Data.Foldable (find)

import Control.Monad.State.Strict hiding (join)
import Debug.Trace


-- Assume a class where we can do predicate transformation through function tau
-- and we can merge two predicates through function join.
-- The initial predicate is given by p0.
-- Moreover, we assume an implementation of a function "implies".
class (Show pred) => Propagator ctxt pred where
  tau     :: ctxt -> CFG -> Int -> Maybe Int -> pred -> pred
  join    :: ctxt -> pred -> pred -> pred
  implies :: ctxt -> pred -> pred -> Bool

supremum :: Propagator ctxt pred => ctxt -> [pred] -> pred
supremum ctxt = foldr1 (join ctxt)


-- the set of next blocks from the given block
post g blockId =
  case IM.lookup blockId (cfg_edges g) of
    Nothing -> IS.empty
    Just ns -> ns

-- the set of edges starting in v
out_edges g v = S.fromList $ zip (repeat v) $ IS.toList $ post g v


-- pick edges from the bag, preferring edges to already visited nodes
pick_edge_from_bag :: State (IM.IntMap pred, S.Set (Int,Int)) (Maybe ((Int,Int), S.Set (Int,Int)))
pick_edge_from_bag = do
  (m,bag) <- get
  case find (\(v0,v1) -> IM.member v1 m) bag of
    Just edge -> return $ Just (edge, S.delete edge bag)
    Nothing   -> return $ S.minView bag
  

-- propagation
-- The state consists of 
-- 		1.) the current mapping of addresses to predicates 
-- 		2.) the current bag (a set of edges to be explored)
prop :: Propagator ctxt pred => ctxt -> CFG -> State (IM.IntMap pred, S.Set (Int,Int)) ()
prop ctxt g = do
  pick <- pick_edge_from_bag
  case pick of
    Nothing ->
      return ()
    Just ((v0,v1),bag') -> do
      m <- gets fst
      -- take an edge (v0,v1) out of the bag
      put (m,bag')
      -- do predicate transformation on the currently available precondition of v0
      let p = im_lookup "v0 must have predicate" m v0
      -- this produces q: the precondition for v1
      let q = tau ctxt g v0 (Just v1) p
      -- store q
      add_predicate q v1
      -- continue
      prop ctxt g
 where
  add_predicate q v1 = do
   (m,bag) <- get
   case IM.lookup v1 m of
     Nothing -> do
       -- first time visit, store q and explore all outgoing edges
       put (IM.insert v1 q m, S.union bag $ out_edges g v1)
     Just p -> do
       let j = join ctxt p q
       if implies ctxt q p then
         -- previously visited, no need for further exploration
         put (IM.insert v1 j m, bag)
       else do
         -- previously visited, no need to weaken invariant by joining
         put (IM.insert v1 j m,S.union bag $ out_edges g v1)

-- start propagation at the given entry address
do_prop :: Propagator ctxt pred => ctxt -> CFG -> Int -> pred -> IM.IntMap pred
do_prop ctxt g entry p = fst $ execState (prop ctxt g) $ (IM.singleton entry p, out_edges g entry)




