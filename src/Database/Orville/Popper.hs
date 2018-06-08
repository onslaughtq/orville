{-|
Module    : Database.Orville.Popper
Copyright : Flipstone Technology Partners 2016-2018
License   : MIT
-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Database.Orville.Popper
  ( PopError(..)
  , Popper
  , Popped(..)
  , (>>>)
  , (<<<)
  , abortPop
  , certainly
  , certainly'
  , fromKern
  , hasMany
  , hasManyIn
  , hasOneIn
  , hasManyInWhere
  , hasManyWhere
  , hasOne
  , hasOne'
  , hasOneWhere
  , kern
  , missingRecordMessage
  , popMissingRecord
  , onKern
  , pop
  , popThrow
  , popFirst
  , popMany
  , onPopMany
  , popMaybe
  , popQuery
  , popRecord
  , popRecord'
  , popTable
  , explain
  , explainLines
  ) where

import Prelude hiding ((.))

import Control.Applicative
import Control.Arrow
import Control.Category
import Control.Monad.Catch
import Data.Either
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe

import Database.Orville.Core
import Database.Orville.Internal.QueryCache
import Database.Orville.Internal.SelectOptions

-- Simple helpers and such that make the public API
kern :: Popper a a
kern = PopId

fromKern :: (a -> b) -> Popper a b
fromKern f = f <$> kern

onKern :: (a -> b -> c) -> Popper b a -> Popper b c
onKern mkPuff popper = mkPuff <$> popper <*> kern

liftPop :: (a -> Popped b) -> Popper a b
liftPop = PopLift

abortPop :: PopError -> Popper a b
abortPop = PopAbort

{-|
   popQuery embeds an Orville operation in a popper. It is left up to the
   programmer to ensure that the Orville operation does not do any updates
   to the database, but only does queries.

   The initial string argument is a description of the query to put into
   the results of `explain`
-}
popQuery :: String -> Orville b -> Popper a b
popQuery = PopQuery

certainly :: PopError -> Popper (Maybe b) b
certainly err = liftPop $ maybe (PoppedError err) PoppedValue

certainly' :: Popper a PopError -> Popper a (Maybe b) -> Popper a b
certainly' msgPopper bPopper =
  (msgPopper &&& bPopper) >>>
  liftPop (\(err, maybeB) -> maybe (PoppedError err) PoppedValue maybeB)

popRecord ::
     TableDefinition readEntity writeEntity key
  -> key
  -> Popper a (Maybe readEntity)
popRecord tableDef key = popQuery explanation (findRecord tableDef key)
  where
    explanation = "popRecord " ++ tableName tableDef

popRecord' ::
     TableDefinition readEntity writeEntity key -> key -> Popper a readEntity
popRecord' td key = popRecord td key >>> certainly err
  where
    err = MissingRecord td (tablePrimaryKey td) key

popFirst ::
     TableDefinition readEntity writeEntity key
  -> SelectOptions
  -> Popper a (Maybe readEntity)
popFirst tableDef opts = popQuery explanation (selectFirst tableDef opts)
  where
    explanation = "popFirst " ++ tableName tableDef

popTable ::
     TableDefinition readEntity writeEntity key
  -> SelectOptions
  -> Popper a [readEntity]
popTable tableDef opts = popQuery explanation (selectAll tableDef opts)
  where
    explanation =
      "popTable " ++ tableName tableDef ++ " " ++ selectOptClause opts

popMaybe :: Popper a b -> Popper (Maybe a) (Maybe b)
popMaybe = PopMaybe

hasMany ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> Popper fieldValue [readEntity]
hasMany tableDef fieldDef = PopRecordManyBy tableDef fieldDef mempty

hasOneIn ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> Popper [fieldValue] (Map.Map fieldValue readEntity)
hasOneIn tableDef fieldDef = PopRecordsBy tableDef fieldDef mempty

hasManyIn ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> Popper [fieldValue] (Map.Map fieldValue [readEntity])
hasManyIn tableDef fieldDef = PopRecordsManyBy tableDef fieldDef mempty

hasManyWhere ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> SelectOptions
  -> Popper fieldValue [readEntity]
hasManyWhere = PopRecordManyBy

hasManyInWhere ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> SelectOptions
  -> Popper [fieldValue] (Map.Map fieldValue [readEntity])
hasManyInWhere = PopRecordsManyBy

hasOne ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> Popper fieldValue (Maybe readEntity)
hasOne tableDef fieldDef = hasOneWhere tableDef fieldDef mempty

hasOneWhere ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> SelectOptions
  -> Popper fieldValue (Maybe readEntity)
hasOneWhere = PopRecordBy

hasOne' ::
     Ord fieldValue
  => TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> Popper fieldValue readEntity
hasOne' tableDef fieldDef =
  certainly' (popMissingRecord tableDef fieldDef) (hasOne tableDef fieldDef)

popMissingRecord ::
     TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> Popper fieldValue PopError
popMissingRecord tableDef fieldDef = fromKern (MissingRecord tableDef fieldDef)

-- popMany is the most involved helper. It recursively
-- rewrites the entire Popper expression to avoid
-- running the popper's queries individually for each
-- item in the list.
--
-- This is where the magic happens.
--
popMany :: Popper a b -> Popper [a] [b]
popMany (PopOnMany _ manyPopper) = manyPopper
popMany (PopRecord tableDef) =
  zipWith Map.lookup <$> kern <*> (repeat <$> PopRecords tableDef)
popMany (PopRecordBy tableDef fieldDef selectOptions) =
  zipWith Map.lookup <$> kern <*>
  (repeat <$> PopRecordsBy tableDef fieldDef selectOptions)
popMany (PopRecordManyBy tableDef fieldDef opts) =
  zipWith getRecords <$> kern <*>
  (repeat <$> PopRecordsManyBy tableDef fieldDef opts)
  where
    getRecords key = fromMaybe [] . Map.lookup key
popMany (PopRecords tableDef) =
  (zipWith restrictMap) <$> kern <*>
  (fromKern concat >>> PopRecords tableDef >>> fromKern repeat)
  where
    restrictMap keys = Map.filterWithKey (isKey keys)
    isKey keys key _ = key `elem` keys
popMany (PopRecordsManyBy tableDef fieldDef opts) =
  (zipWith restrictMap) <$> kern <*>
  (fromKern concat >>>
   PopRecordsManyBy tableDef fieldDef opts >>> fromKern repeat)
  where
    restrictMap keys = Map.filterWithKey (isKey keys)
    isKey keys key _ = key `elem` keys
popMany (PopRecordsBy tableDef fieldDef opts) =
  (zipWith restrictMap) <$> kern <*>
  (fromKern concat >>> PopRecordsBy tableDef fieldDef opts >>> fromKern repeat)
  where
    restrictMap keys = Map.filterWithKey (isKey keys)
    isKey keys key _ = key `elem` keys
popMany PopId = PopId
popMany (PopAbort err) = (PopAbort err)
popMany (PopPure a) = PopPure (repeat a) -- lists here should be treated as
                     -- ZipLists, so 'repeat' is 'pure'
popMany (PopLift f) =
  PopLift $ \inputs ->
    let poppeds = map f inputs
        extract (PoppedValue b) (PoppedValue bs) = PoppedValue (b : bs)
        extract _ (PoppedError err) = PoppedError err
        extract (PoppedError err) _ = PoppedError err
     in foldr extract (PoppedValue []) poppeds
popMany (PopMap f popper) = PopMap (fmap f) (popMany popper)
popMany (PopApply fPopper aPopper) =
  getZipList <$>
  PopApply
    (fmap (<*>) (ZipList <$> popMany fPopper))
    (ZipList <$> popMany aPopper)
popMany (PopChain bPopper aPopper) =
  PopChain (popMany bPopper) (popMany aPopper)
popMany (PopArrowFirst popper) =
  fromKern unzip >>> first (popMany popper) >>> fromKern (uncurry zip)
popMany (PopArrowLeft popper) =
  rebuildList <$> kern <*> (fromKern lefts >>> popMany popper)
  where
    rebuildList [] _ = []
    rebuildList (Left _:_) [] = [] -- shouldn't happen?
    rebuildList (Right c:eacs) bs = Right c : rebuildList eacs bs
    rebuildList (Left _:eacs) (b:bs) = Left b : rebuildList eacs bs
popMany (PopMaybe singlePopper) =
  rebuildList <$> kern <*> (fromKern catMaybes >>> popMany singlePopper)
  where
    rebuildList [] _ = []
    rebuildList (Just _:_) [] = [] -- shouldn't happen?
    rebuildList (Nothing:as) bs = Nothing : rebuildList as bs
    rebuildList (Just _:as) (b:bs) = Just b : rebuildList as bs
popMany (PopQuery explanation orm)
  -- the orm query here doesn't depend on the Popper input,
  -- so we can run it once and then construct an infinite
  -- list of the results to be lined up as the outputs for
  -- each input in the list
  --
  -- ('repeat' is 'pure' since lists here are zipped)
  --
 = PopQuery explanation (repeat <$> orm)

-- Manually specifies the many handling of a popper. The original popper
-- is lift unchanged. If it becomes involved in a `popMany` operation, the
-- provided popper with be substituted for it, rather than apply the normal
-- popper re-write rules.
--
-- This is useful if either of the cases can manually optimized in a way that
-- is incompatible with the normal popping mechanisms
--
onPopMany :: Popper a b -> Popper [a] [b] -> Popper a b
onPopMany = PopOnMany

-- The Popper guts
data PopError
  = forall readEntity writeEntity key fieldValue. MissingRecord (TableDefinition readEntity writeEntity key)
                                                                (FieldDefinition fieldValue)
                                                                fieldValue
  | Unpoppable String

instance Show PopError where
  show (MissingRecord tableDef fieldDef fieldValue) =
    "MissingRecord: " ++ missingRecordMessage tableDef fieldDef fieldValue
  show (Unpoppable msg) = "Unpoppable: " ++ msg

missingRecordMessage ::
     TableDefinition readEntity writeEntity key
  -> FieldDefinition fieldValue
  -> fieldValue
  -> String
missingRecordMessage tableDef fieldDef fieldValue =
  concat
    [ "Unable to find "
    , tableName tableDef
    , " with "
    , fieldName fieldDef
    , " = "
    , show (fieldToSqlValue fieldDef fieldValue)
    ]

instance Exception PopError

data Popped a
  = PoppedValue a
  | PoppedError PopError

instance Functor Popped where
  fmap f (PoppedValue a) = PoppedValue (f a)
  fmap _ (PoppedError err) = PoppedError err

instance Applicative Popped where
  pure = PoppedValue
  (PoppedValue f) <*> (PoppedValue a) = PoppedValue (f a)
  (PoppedError err) <*> _ = PoppedError err
  _ <*> (PoppedError err) = PoppedError err

-- Popper GADT. This defines the popper expression dsl
-- that is used internally to represent poppers. These
-- constructors are not exposed, so they can be changed
-- freely as long as the exported API is stable.
--
data Popper a b where
  PopQuery :: String -> Orville b -> Popper a b
  PopRecord
    :: Ord key
    => TableDefinition readEntity writeEntity key
    -> Popper key (Maybe readEntity)
  PopRecords
    :: Ord key
    => TableDefinition readEntity writeEntity key
    -> Popper [key] (Map.Map key readEntity)
  PopRecordBy
    :: Ord fieldValue
    => TableDefinition readEntity writeEntity key
    -> FieldDefinition fieldValue
    -> SelectOptions
    -> Popper fieldValue (Maybe readEntity)
  PopRecordManyBy
    :: Ord fieldValue
    => TableDefinition readEntity writeEntity key
    -> FieldDefinition fieldValue
    -> SelectOptions
    -> Popper fieldValue [readEntity]
  PopRecordsBy
    :: Ord fieldValue
    => TableDefinition readEntity writeEntity key
    -> FieldDefinition fieldValue
    -> SelectOptions
    -> Popper [fieldValue] (Map.Map fieldValue readEntity)
  PopRecordsManyBy
    :: Ord fieldValue
    => TableDefinition readEntity writeEntity key
    -> FieldDefinition fieldValue
    -> SelectOptions
    -> Popper [fieldValue] (Map.Map fieldValue [readEntity])
  PopId :: Popper a a
  PopPure :: b -> Popper a b
  PopLift :: (a -> Popped b) -> Popper a b
  PopAbort :: PopError -> Popper a b
  PopMap :: (b -> c) -> Popper a b -> Popper a c
  PopApply :: Popper a (b -> c) -> Popper a b -> Popper a c
  PopChain :: Popper b c -> Popper a b -> Popper a c
  PopArrowFirst :: Popper a b -> Popper (a, c) (b, c)
  PopArrowLeft :: Popper a b -> Popper (Either a c) (Either b c)
  PopOnMany :: Popper a b -> Popper [a] [b] -> Popper a b
  PopMaybe :: Popper a b -> Popper (Maybe a) (Maybe b)

instance Functor (Popper a) where
  fmap = PopMap

instance Applicative (Popper a) where
  pure = PopPure
  (<*>) = PopApply

instance Category Popper where
  id = PopId
  (.) = PopChain

instance Arrow Popper where
  arr = fromKern
  first = PopArrowFirst

instance ArrowChoice Popper where
  left = PopArrowLeft

popThrow :: Popper a b -> a -> Orville b
popThrow popper a = do
  popped <- pop popper a
  case popped of
    PoppedValue b -> return b
    PoppedError e -> throwM e

-- This is where the action happens. pop converts the
-- Popper DSL into Orville calls with the provided input
--
pop :: Popper a b -> a -> Orville (Popped b)
pop popper a = runQueryCached $ popCached popper a

popCached ::
     (MonadThrow m, MonadOrville conn m)
  => Popper a b
  -> a
  -> QueryCached m (Popped b)
popCached (PopOnMany singlePopper _) a = popCached singlePopper a
popCached (PopQuery _ query) _ = PoppedValue <$> unsafeLift query
popCached (PopRecordBy tableDef fieldDef opts) recordId =
  PoppedValue <$>
  selectFirstCached tableDef (where_ (fieldDef .== recordId) <> opts)
popCached (PopRecordManyBy tableDef fieldDef opts) recordId =
  PoppedValue <$>
  selectCached tableDef (where_ (fieldDef .== recordId) <> opts)
popCached (PopRecordsBy tableDef fieldDef opts) recordIds =
  PoppedValue <$> Map.map head <$>
  findRecordsByCached
    tableDef
    fieldDef
    (where_ (fieldDef .<- recordIds) <> opts)
popCached (PopRecordsManyBy tableDef fieldDef opts) recordIds =
  PoppedValue <$>
  findRecordsByCached
    tableDef
    fieldDef
    (where_ (fieldDef .<- recordIds) <> opts)
popCached (PopRecord tableDef) recordId =
  PoppedValue <$> findRecordCached tableDef recordId
popCached (PopRecords tableDef) recordIds =
  PoppedValue <$> findRecordsCached tableDef recordIds
popCached (PopAbort err) _ = pure (PoppedError err)
popCached PopId a = pure (PoppedValue a)
popCached (PopPure a) _ = pure (PoppedValue a)
popCached (PopLift f) a = pure (f a)
popCached (PopMap f popper) a = fmap f <$> popCached popper a
popCached (PopApply fPopper bPopper) a =
  (fmap (<*>) (popCached fPopper a)) <*> popCached bPopper a
popCached (PopChain popperB popperA) a = do
  value <- popCached popperA a
  case value of
    PoppedError err -> pure (PoppedError err)
    PoppedValue b -> popCached popperB b
popCached (PopArrowFirst popper) (a, c) = do
  poppedB <- popCached popper a
  case poppedB of
    PoppedValue b -> return (PoppedValue (b, c))
    PoppedError err -> return (PoppedError err)
popCached (PopArrowLeft popper) ac = do
  case ac of
    Left a -> fmap Left <$> popCached popper a
    Right c -> pure (PoppedValue (Right c))
popCached (PopMaybe popper) a =
  case a of
    Nothing -> pure (PoppedValue Nothing)
    Just val -> fmap Just <$> popCached popper val

explain :: Popper a b -> String
explain = unlines . explainLines

explainLines :: Popper a b -> [String]
explainLines subject =
  case subject of
    PopQuery explanation _ -> [explanation]
    PopRecord tableDef ->
      let entity = tableName tableDef
          field = fieldName (tablePrimaryKey tableDef)
       in [intercalate " " ["fetch one", entity, "by one", field]]
    PopRecords tableDef ->
      let entity = tableName tableDef
          field = fieldName (tablePrimaryKey tableDef)
       in [intercalate " " ["fetch many", entity, "by many", field]]
    PopRecordBy tableDef fieldDef opts ->
      let entity = tableName tableDef
          field = fieldName fieldDef
       in [ intercalate
              " "
              ["fetch one", entity, "by one", field, explainSelectOpts opts]
          ]
    PopRecordManyBy tableDef fieldDef opts ->
      let entity = tableName tableDef
          field = fieldName fieldDef
       in [ intercalate
              " "
              ["fetch many", entity, "by one", field, explainSelectOpts opts]
          ]
    PopRecordsBy tableDef fieldDef opts ->
      let entity = tableName tableDef
          field = fieldName fieldDef
       in [ intercalate
              " "
              [ "fetch many"
              , entity
              , "by many"
              , field
              , "(1-1)"
              , explainSelectOpts opts
              ]
          ]
    PopRecordsManyBy tableDef fieldDef opts ->
      let entity = tableName tableDef
          field = fieldName fieldDef
       in [ intercalate
              " "
              [ "fetch many"
              , entity
              , "by many"
              , field
              , "(*-1)"
              , explainSelectOpts opts
              ]
          ]
    PopId -> []
    PopPure _ -> []
    PopLift _ -> []
    PopAbort _ -> []
    PopMap _ popper -> explainLines popper
    -- Note the argument order to PopApply in comparison to PopChain below
    PopApply popperA popperB -> explainLines popperA ++ explainLines popperB
    -- Note the argument order to PopApply in comparison to PopApply above
    PopChain popperB popperA -> explainLines popperA ++ explainLines popperB
    PopArrowFirst popper -> explainLines popper
    PopArrowLeft popper -> explainLines popper
    PopOnMany singlePopper _
      -- If a `PopOnMany` is left in the tree at the time of execution, it
      -- always represents a single pop. Other `popMany` would have removed
      -- it from the tree and replaced it with a direct reference to the many
      -- popper that it holds.
     -> explainLines singlePopper
    PopMaybe popper -> explainLines popper

explainSelectOpts :: SelectOptions -> String
explainSelectOpts opts =
  let clause = selectOptClause opts
   in if any (/= ' ') clause
        then concat ["(", clause, "("]
        else ""
