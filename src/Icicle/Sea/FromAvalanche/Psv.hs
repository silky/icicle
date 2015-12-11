{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Sea.FromAvalanche.Psv (
    PsvConfig(..)
  , PsvMode(..)
  , seaOfPsvDriver
  , seaOfStringEq
  ) where

import qualified Data.ByteString as B
import qualified Data.List as List
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Word (Word8)

import           Icicle.Avalanche.Prim.Flat (Prim(..), PrimUpdate(..), PrimUnsafe(..))
import           Icicle.Avalanche.Prim.Flat (meltType)

import           Icicle.Common.Base (OutputName(..))
import           Icicle.Common.Type (ValType(..), StructType(..), StructField(..))
import           Icicle.Common.Type (defaultOfType)

import           Icicle.Data (Attribute(..), Time)

import           Icicle.Internal.Pretty
import qualified Icicle.Internal.Pretty as Pretty

import           Icicle.Sea.Error (SeaError(..))
import           Icicle.Sea.FromAvalanche.Base (seaOfAttributeDesc, seaOfTime)
import           Icicle.Sea.FromAvalanche.Base (seaOfNameIx, seaOfChar)
import           Icicle.Sea.FromAvalanche.Prim
import           Icicle.Sea.FromAvalanche.Program (seaOfXValue)
import           Icicle.Sea.FromAvalanche.State
import           Icicle.Sea.FromAvalanche.Type

import           P

import           Text.Printf (printf)


------------------------------------------------------------------------

data PsvMode
  = PsvSnapshot Time
  | PsvChords
  deriving (Eq, Ord, Show)

data PsvConfig = PsvConfig {
    psvMode       :: PsvMode
  , psvTombstones :: Map Attribute (Set Text)
  } deriving (Eq, Ord, Show)

------------------------------------------------------------------------

seaOfPsvDriver :: [SeaProgramState] -> PsvConfig -> Either SeaError Doc
seaOfPsvDriver states config = do
  let struct_sea  = seaOfFleetState                      states
      alloc_sea   = seaOfAllocFleet                      states
      collect_sea = seaOfCollectFleet                    states
      config_sea  = seaOfConfigureFleet (psvMode config) states
  read_sea  <- seaOfReadAnyFact      config           states
  write_sea <- seaOfWriteFleetOutput (psvMode config) states
  pure $ vsep
    [ struct_sea
    , ""
    , alloc_sea
    , ""
    , collect_sea
    , ""
    , config_sea
    , ""
    , read_sea
    , ""
    , write_sea
    ]

------------------------------------------------------------------------

seaOfFleetState :: [SeaProgramState] -> Doc
seaOfFleetState states
 = let constTime = "const " <> seaOfValType TimeT
   in vsep
      [ "#line 1 \"fleet state\""
      , "struct ifleet {"
      , indent 4 (defOfVar' 1 "imempool_t" "mempool")         <> ";"
      , indent 4 (defOfVar  0 IntT         "max_chord_count") <> ";"
      , indent 4 (defOfVar  0 IntT         "chord_count")     <> ";"
      , indent 4 (defOfVar' 1 constTime    "chord_times")     <> ";"
      , indent 4 (vsep (fmap defOfProgramState states))
      , indent 4 (vsep (fmap defOfProgramTime  states))
      , "};"
      ]

defOfProgramState :: SeaProgramState -> Doc
defOfProgramState state
 = defOfVar' 1 (pretty (nameOfStateType state))
               (pretty (nameOfProgram state)) <> ";"
 <+> "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"

defOfProgramTime :: SeaProgramState -> Doc
defOfProgramTime state
 = defOfVar 0 TimeT (pretty (nameOfLastTime state)) <> ";"
 <+> "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"

nameOfLastTime :: SeaProgramState -> Text
nameOfLastTime state = "last_time_" <> T.pack (show (stateName state))

------------------------------------------------------------------------

seaOfAllocFleet :: [SeaProgramState] -> Doc
seaOfAllocFleet states
 = vsep
 [ "#line 1 \"allocate fleet state\""
 , "static ifleet_t * psv_alloc_fleet (iint_t max_chord_count)"
 , "{"
 , "    ifleet_t *fleet = calloc (1, sizeof (ifleet_t));"
 , ""
 , "    fleet->max_chord_count = max_chord_count;"
 , ""
 , indent 4 (vsep (fmap seaOfAllocProgram states))
 , "    return fleet;"
 , "}"
 ]

seaOfAllocProgram :: SeaProgramState -> Doc
seaOfAllocProgram state
 = let programs  = "fleet->" <> pretty (nameOfProgram state)
       program   = programs <> "[ix]."
       stype     = pretty (nameOfStateType state)

       calloc n t = "calloc (" <> n <> ", sizeof (" <> t <> "));"

       go (n, t) = program <> pretty (newPrefix <> n)
                <> " = "
                <> calloc "psv_max_row_count" (seaOfValType t)

   in vsep [ "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"
           , programs <> " = " <> calloc "max_chord_count" stype
           , ""
           , "for (iint_t ix = 0; ix < max_chord_count; ix++) {"
           , indent 4 (vsep (fmap go (stateInputVars state)))
           , "}"
           , ""
           ]

------------------------------------------------------------------------

seaOfCollectFleet :: [SeaProgramState] -> Doc
seaOfCollectFleet states
 = vsep
 [ "#line 1 \"collect fleet state\""
 , "static void psv_collect_fleet (ifleet_t *fleet)"
 , "{"
 , "    imempool_t *into_pool       = imempool_create ();"
 , "    imempool_t *last_pool       = fleet->mempool;"
 , "    iint_t      max_chord_count = fleet->max_chord_count;"
 , "    iint_t      chord_count     = fleet->chord_count;"
 , ""
 , indent 4 (vsep (fmap seaOfCollectProgram states))
 , ""
 , "    fleet->mempool = into_pool;"
 , ""
 , "    for (iint_t ix = 0; ix < max_chord_count; ix++) {"
 , indent 8 (vsep (fmap seaOfAssignMempool states))
 , "    }"
 , ""
 , "    if (last_pool != 0) {"
 , "        imempool_free (last_pool);"
 , "    }"
 , "}"
 ]

seaOfAssignMempool :: SeaProgramState -> Doc
seaOfAssignMempool state
 = let pname = pretty (nameOfProgram state)
   in "fleet->" <> pname <> "[ix].mempool = into_pool;"

seaOfCollectProgram :: SeaProgramState -> Doc
seaOfCollectProgram state
 = let pname = pretty (nameOfProgram state)
       stype = pretty (nameOfStateType state)
       pvar  = "program->"

       new n = pvar <> pretty (newPrefix <> n)
       res n = pvar <> pretty (resPrefix <> n)

       copyInputs nts
        = let docs = concatMap copyInput (stateInputVars state)
          in if List.null docs
             then []
             else [ "iint_t new_count = " <> pvar <> "new_count;"
                  , ""
                  , "for (iint_t ix = 0; ix < new_count; ix++) {"
                  , indent 4 $ vsep $ concatMap copyInput nts
                  , "}"
                  ]

       copyInput (n, t)
        | not (needsCopy t)
        = []

        | otherwise
        = [ new n <> "[ix] = " <> prefixOfValType t <> "copy (into_pool, " <> new n <> "[ix]);" ]

       copyResumable (n, t)
        | not (needsCopy t)
        = []

        | otherwise
        = [ ""
          , "if (" <> pvar <> pretty (hasPrefix <> n) <> ") {"
          , indent 4 (res n <> " = " <> prefixOfValType t <> "copy (into_pool, " <> res n <> ");")
          , "}"
          ]

   in vsep [ "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"
           , "for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
           , indent 4 $ stype <+> "*program = &fleet->" <> pname <> "[chord_ix];"
           , ""
           , "    if (last_pool != 0) {"
           , indent 8 $ vsep $ copyInputs (stateInputVars state)
                            <> concatMap copyResumable (stateResumables state)
           , "    }"
           , "}"
           ]

needsCopy :: ValType -> Bool
needsCopy = \case
  StringT   -> True
  ArrayT{}  -> True
  BufT{}    -> True

  UnitT     -> False
  BoolT     -> False
  IntT      -> False
  DoubleT   -> False
  TimeT     -> False
  ErrorT    -> False

  -- these should have been melted
  PairT{}   -> False
  OptionT{} -> False
  StructT{} -> False
  SumT{}    -> False
  MapT{}    -> False

------------------------------------------------------------------------

seaOfConfigureFleet :: PsvMode -> [SeaProgramState] -> Doc
seaOfConfigureFleet mode states
 = vsep
 [ "#line 1 \"configure fleet state\""
 , "static ierror_loc_t psv_configure_fleet (const char *entity, size_t entity_size, const ichord_t **chord, ifleet_t *fleet)"
 , "{"
 , "    iint_t max_chord_count = fleet->max_chord_count;"
 , ""
 , "    iint_t         chord_count;"
 , "    const itime_t *chord_times;"
 , ""
 , case mode of
     PsvSnapshot time -> indent 4 (seaOfChordTimes [time])
     PsvChords        -> indent 4 seaOfChordScan
 , ""
 , "    if (chord_count > max_chord_count) {"
 , "        return ierror_loc_format"
 , "            ( 0, 0"
 , "            , \"exceeded maximum number of chords per entity (chord_count = %lld, max_chord_count = %lld)\""
 , "            , chord_count"
 , "            , max_chord_count );"
 , "    }"
 , ""
 , "    fleet->chord_count = chord_count;"
 , "    fleet->chord_times = chord_times;"
 , ""
 , indent 4 (vsep (fmap defOfState states))
 , ""
 , "    for (iint_t ix = 0; ix < chord_count; ix++) {"
 , "        itime_t chord_time = chord_times[ix];"
 , ""
 , indent 8 (vsep (fmap seaOfAssignTime states))
 , "    }"
 , ""
 , indent 4 (vsep (fmap defOfLastTime states))
 , ""
 , "    return 0;"
 , "}"
 ]

defOfState :: SeaProgramState -> Doc
defOfState state
 = let stype  = pretty (nameOfStateType state)
       var    = "*p" <> pretty (stateName state)
       member = "fleet->" <> pretty (nameOfProgram state)
   in stype <+> var <+> "=" <+> member <> ";"

defOfLastTime :: SeaProgramState -> Doc
defOfLastTime state
 = "fleet->" <> pretty (nameOfLastTime state) <+> "= 0;"

seaOfAssignTime :: SeaProgramState -> Doc
seaOfAssignTime state
 = let ptime = "p" <> pretty (stateName state) <> "[ix]." <> pretty (stateTimeVar state)
   in ptime <+> "=" <+> "chord_time;"

seaOfChordTimes :: [Time] -> Doc
seaOfChordTimes times
 = vsep
 [ "static const itime_t entity_times[] = { " <> hcat (punctuate ", " (fmap seaOfTime times)) <> " };"
 , ""
 , "chord_count = " <> int (length times) <> ";"
 , "chord_times = entity_times;"
 ]

seaOfChordScan :: Doc
seaOfChordScan
 = "*chord = ichord_scan (*chord, entity, entity_size, &chord_count, &chord_times);"

------------------------------------------------------------------------

seaOfReadAnyFact :: PsvConfig -> [SeaProgramState] -> Either SeaError Doc
seaOfReadAnyFact config states = do
  let tss = fmap (lookupTombstones config) states
  readStates_sea <- zipWithM seaOfReadFact states tss
  pure $ vsep
    [ vsep readStates_sea
    , ""
    , "#line 1 \"read any fact\""
    , "static ierror_loc_t psv_read_fact"
    , "  ( const char   *attrib_ptr"
    , "  , const size_t  attrib_size"
    , "  , const char   *value_ptr"
    , "  , const size_t  value_size"
    , "  , const char   *time_ptr"
    , "  , const size_t  time_size"
    , "  , ifleet_t     *fleet )"
    , "{"
    , indent 4 (vsep (fmap seaOfReadNamedFact states))
    , "    return 0;"
    , "}"
    ]

seaOfReadNamedFact :: SeaProgramState -> Doc
seaOfReadNamedFact state
 = let attrib = getAttribute (stateAttribute state)
       fun    = pretty (nameOfReadFact state)
       pname  = pretty (nameOfProgram  state)
       tname  = pretty (nameOfLastTime state)
   in vsep
      [ "/* " <> pretty attrib <> " */"
      , "if (" <> seaOfStringEq attrib "attrib_ptr" (Just "attrib_size") <> ") {"
      , "    itime_t time;"
      , "    ierror_loc_t error = fixed_read_itime (time_ptr, time_size, &time);"
      , "    if (error) return error;"
      , ""
      , "    ibool_t        ignore_time = itrue;"
      , "    iint_t         chord_count = fleet->chord_count;"
      , "    const itime_t *chord_times = fleet->chord_times;"
      , ""
      , "    /* ignore this time if it comes after all the chord times */"
      , "    for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
      , "        if (chord_times[chord_ix] >= time) {"
      , "            ignore_time = ifalse;"
      , "            break;"
      , "        }"
      , "    }"
      , ""
      , "    if (ignore_time) return 0;"
      , ""
      , "    itime_t last_time = fleet->" <> tname <> ";"
      , ""
      , "    if (time <= last_time) {"
      , "        char curr_time_ptr[text_itime_max_size];"
      , "        size_t curr_time_size = text_write_itime (time, curr_time_ptr);"
      , ""
      , "        char last_time_ptr[text_itime_max_size];"
      , "        size_t last_time_size = text_write_itime (last_time, last_time_ptr);"
      , ""
      , "        return ierror_loc_format"
      , "           ( time_ptr + time_size"
      , "           , time_ptr"
      , "           , \"%.*s: time is out of order: %.*s must be later than %.*s\""
      , "           , attrib_size"
      , "           , attrib_ptr"
      , "           , curr_time_size"
      , "           , curr_time_ptr"
      , "           , last_time_size"
      , "           , last_time_ptr );"
      , "    }"
      , ""
      , "    fleet->" <> tname <> " = time;"
      , ""
      , "    return " <> fun <> " (value_ptr, value_size, time, fleet->mempool, chord_count, fleet->" <> pname <> ");"
      , "}"
      , ""
      ]

------------------------------------------------------------------------

nameOfReadFact :: SeaProgramState -> Text
nameOfReadFact state = T.pack ("psv_read_fact_" <> show (stateName state))

seaOfReadFact :: SeaProgramState -> Set Text -> Either SeaError Doc
seaOfReadFact state tombstones = do
  input     <- checkInputType state
  readInput <- seaOfReadInput input
  pure $ vsep
    [ "#line 1 \"read fact" <+> seaOfStateInfo state <> "\""
    , "static ierror_loc_t INLINE"
        <+> pretty (nameOfReadFact state) <+> "("
        <> "const char *value_ptr, const size_t value_size, itime_t time, "
        <> "imempool_t *mempool, iint_t chord_count, "
        <> pretty (nameOfStateType state) <+> "*programs)"
    , "{"
    , "    ierror_loc_t error;"
    , ""
    , "    char *p  = (char *) value_ptr;"
    , "    char *pe = (char *) value_ptr + value_size;"
    , ""
    , "    ierror_t " <> pretty (inputSumError input) <> ";"
    , indent 4 . vsep . fmap seaOfDefineInput $ inputVars input
    , ""
    , "    " <> align (seaOfReadTombstone input (Set.toList tombstones)) <> "{"
    , "        " <> pretty (inputSumError input) <> " = ierror_not_an_error;"
    , ""
    , indent 8 readInput
    , "    }"
    , ""
    , "    for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
    , "        " <> pretty (nameOfStateType state) <+> "*program = &programs[chord_ix];"
    , ""
    , "        /* don't read values after the chord time */"
    , "        if (time > program->" <> pretty (stateTimeVar state) <> ")"
    , "            continue;"
    , ""
    , "        iint_t new_count = program->new_count;"
    , ""
    , "        program->" <> pretty (inputSumError  input) <> "[new_count] = " <> pretty (inputSumError input) <> ";"
    , indent 8 . vsep . fmap seaOfAssignInput $ inputVars input
    , "        program->" <> pretty (inputTime     input) <> "[new_count] = time;"
    , ""
    , "        new_count++;"
    , ""
    , "        if (new_count == psv_max_row_count) {"
    , "             " <> pretty (nameOfProgram state) <> " (program);"
    , "             new_count = 0;"
    , "        } else if (new_count > psv_max_row_count) {"
    , "             return ierror_loc_format (0, 0, \"" <> pretty (nameOfReadFact state) <> ": new_count > max_count\");"
    , "        }"
    , ""
    , "        program->new_count = new_count;"
    , "    }"
    , ""
    , "    return 0; /* no error */"
    , "}"
    , ""
    ]

seaOfAssignInput :: (Text, ValType) -> Doc
seaOfAssignInput (n, _)
 = "program->" <> pretty n <> "[new_count] = " <> pretty n <> ";"

seaOfDefineInput :: (Text, ValType) -> Doc
seaOfDefineInput (n, t)
 = seaOfValType t <+> pretty n <> initType t

initType :: ValType -> Doc
initType vt = " = " <> seaOfXValue (defaultOfType vt) vt <> ";"

------------------------------------------------------------------------

seaOfReadTombstone :: CheckedInput -> [Text] -> Doc
seaOfReadTombstone input = \case
  []     -> Pretty.empty
  (t:ts) -> "if (" <> seaOfStringEq t "value_ptr" (Just "value_size") <> ") {" <> line
         <> "    " <> pretty (inputSumError input) <> " = ierror_tombstone;" <> line
         <> "} else " <> seaOfReadTombstone input ts

------------------------------------------------------------------------

data CheckedInput = CheckedInput {
    inputSumError :: Text
  , inputTime     :: Text
  , inputType     :: ValType
  , inputVars     :: [(Text, ValType)]
  } deriving (Eq, Ord, Show)

checkInputType :: SeaProgramState -> Either SeaError CheckedInput
checkInputType state
 = case stateInputType state of
     PairT (SumT ErrorT t) TimeT
      | (sumError, ErrorT) : xs0 <- stateInputVars state
      , Just vars                <- init xs0
      , Just (time, TimeT)       <- last xs0
      -> Right CheckedInput {
             inputSumError = newPrefix <> sumError
           , inputTime     = newPrefix <> time
           , inputType     = t
           , inputVars     = fmap (first (newPrefix <>)) vars
           }

     t
      -> Left (SeaUnsupportedInputType t)

seaOfReadInput :: CheckedInput -> Either SeaError Doc
seaOfReadInput input
 = case (inputVars input, inputType input) of
    ([(nx, BoolT)], BoolT)
     -> pure (readValue "text" assignVar nx BoolT)

    ([(nx, DoubleT)], DoubleT)
     -> pure (readValue "text" assignVar nx DoubleT)

    ([(nx, IntT)], IntT)
     -> pure (readValue "text" assignVar nx IntT)

    ([(nx, TimeT)], TimeT)
     -> pure (readValue "text" assignVar nx TimeT)

    ([(nx, StringT)], StringT)
     -> pure (readValuePool "text" assignVar nx StringT)

    (_, t@(ArrayT _))
     -> seaOfReadJsonValue assignVar t (inputVars input)

    (_, t@(StructT _))
     -> seaOfReadJsonValue assignVar t (inputVars input)

    (_, t)
     -> Left (SeaUnsupportedInputType t)

------------------------------------------------------------------------

-- Describes how to assign to a C struct member, this changes for arrays
type Assignment = Doc -> ValType -> Doc -> Doc

assignVar :: Assignment
assignVar n _ x = pretty n <+> "=" <+> x <> ";"

assignArray :: Assignment
assignArray n t x = n <+> "=" <+> seaOfArrayPut n "ix" x t <> ";"

seaOfArrayPut :: Doc -> Doc -> Doc -> ValType -> Doc
seaOfArrayPut arr ix val typ
 = seaOfPrimDocApps (seaOfXPrim (PrimUpdate (PrimUpdateArrayPut typ)))
                    [ arr, ix, val ]

seaOfArrayIndex :: Doc -> Doc -> ValType -> Doc
seaOfArrayIndex arr ix typ
 = seaOfPrimDocApps (seaOfXPrim (PrimUnsafe (PrimUnsafeArrayIndex typ)))
                    [ arr, ix ]

------------------------------------------------------------------------

seaOfReadJsonValue :: Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonValue assign vtype vars
 = case (vars, vtype) of
     ([(nb, BoolT), nx], OptionT t) -> do
       val_sea <- seaOfReadJsonValue assign t [nx]
       pure $ vsep
         [ "ibool_t is_null;"
         , "error = json_try_read_null (&p, pe, &is_null);"
         , "if (error) return error;"
         , ""
         , "if (is_null) {"
         , indent 4 (assign (pretty nb) BoolT "ifalse")
         , "} else {"
         , indent 4 (assign (pretty nb) BoolT "itrue")
         , ""
         , indent 4 val_sea
         , "}"
         ]

     ([(nx, BoolT)], BoolT)
      -> pure (readValue "json" assign nx BoolT)

     ([(nx, IntT)], IntT)
      -> pure (readValue "json" assign nx IntT)

     ([(nx, DoubleT)], DoubleT)
      -> pure (readValue "json" assign nx DoubleT)

     ([(nx, TimeT)], TimeT)
      -> pure (readValue "json" assign nx TimeT)

     ([(nx, StringT)], StringT)
      -> pure (readValuePool "json" assign nx StringT)

     (ns, StructT t)
      -> seaOfReadJsonObject assign t ns

     (ns, ArrayT t)
      -> seaOfReadJsonList t ns

     _
      -> Left (SeaInputTypeMismatch vtype vars)

------------------------------------------------------------------------

readValue :: Doc -> Assignment -> Text -> ValType -> Doc
readValue
 = readValueArg ""

readValuePool :: Doc -> Assignment -> Text -> ValType -> Doc
readValuePool
 = readValueArg "mempool, "

readValueArg :: Doc -> Doc -> Assignment -> Text -> ValType -> Doc
readValueArg arg fmt assign n vt
 = vsep
 [ seaOfValType vt <+> "value;"
 , "error = " <> fmt <> "_read_" <> baseOfValType vt <> " (" <> arg <> "&p, pe, &value);"
 , "if (error) return error;"
 , assign (pretty n) vt "value"
 ]

------------------------------------------------------------------------

seaOfReadJsonList :: ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonList vtype avars = do
  vars      <- traverse unArray avars
  value_sea <- seaOfReadJsonValue assignArray vtype vars
  pure $ vsep
    [ "if (*p++ != '[')"
    , "    return ierror_loc_format (p-1, p-1, \"array missing '['\");"
    , ""
    , "char term = *p;"
    , ""
    , "for (iint_t ix = 0; term != ']'; ix++) {"
    , indent 4 value_sea
    , "    "
    , "    term = *p++;"
    , "    if (term != ',' && term != ']')"
    , "        return ierror_loc_format (p-1, p-1, \"array separator ',' or terminator ']' not found\");"
    , "}"
    ]

unArray :: (Text, ValType) -> Either SeaError (Text, ValType)
unArray (n, ArrayT t) = Right (n, t)
unArray (n, t)        = Left (SeaInputTypeMismatch t [(n, t)])

------------------------------------------------------------------------

seaOfReadJsonObject :: Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonObject assign st@(StructType fs) vars
 = case vars of
    [(nx, UnitT)] | Map.null fs -> seaOfReadJsonUnit   assign nx
    _                           -> seaOfReadJsonStruct assign st vars

seaOfReadJsonUnit :: Assignment -> Text -> Either SeaError Doc
seaOfReadJsonUnit assign name = do
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return ierror_loc_format (p-1, p-1, \"unit missing '{'\");"
    , ""
    , "if (*p++ != '}')"
    , "    return ierror_loc_format (p-1, p-1, \"unit missing '}'\");"
    , ""
    , assign (pretty name) UnitT "iunit"
    ]

seaOfReadJsonStruct :: Assignment -> StructType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonStruct assign st@(StructType fields) vars = do
  let mismatch = SeaStructFieldsMismatch st vars
  mappings     <- maybe (Left mismatch) Right (mappingOfFields (Map.toList fields) vars)
  mappings_sea <- traverse (seaOfFieldMapping assign) mappings
  pure $ vsep
    [ "if (*p++ != '{')"
    , "    return ierror_loc_format (p-1, p-1, \"struct missing '{'\");"
    , ""
    , "for (;;) {"
    , "    if (*p++ != '\"')"
    , "        return ierror_loc_format (p-1, p-1, \"field name missing opening quote\");"
    , ""
    , indent 4 (vsep mappings_sea)
    , "    return ierror_loc_format (p-1, p-1, \"invalid field start\");"
    , "}"
    ]

seaOfFieldMapping :: Assignment -> FieldMapping -> Either SeaError Doc
seaOfFieldMapping assign (FieldMapping fname ftype vars) = do
  let needle = fname <> "\""
  field_sea <- seaOfReadJsonField assign ftype vars
  pure $ vsep
    [ "/* " <> pretty fname <> " */"
    , "if (" <> seaOfStringEq needle "p" Nothing <> ") {"
    , "    p += " <> int (sizeOfString needle) <> ";"
    , ""
    , indent 4 field_sea
    , ""
    , "    continue;"
    , "}"
    , ""
    ]

seaOfReadJsonField :: Assignment -> ValType -> [(Text, ValType)] -> Either SeaError Doc
seaOfReadJsonField assign ftype vars = do
  value_sea <- seaOfReadJsonValue assign ftype vars
  pure $ vsep
    [ "if (*p++ != ':')"
    , "    return ierror_loc_format (p-1, p-1, \"field missing ':'\");"
    , ""
    , value_sea
    , ""
    , "char term = *p++;"
    , "if (term != ',' && term != '}')"
    , "    return ierror_loc_format (p-1, p-1, \"field separator ',' or terminator '}' not found\");"
    , ""
    , "if (term == '}')"
    , "    break;"
    ]

------------------------------------------------------------------------

data FieldMapping = FieldMapping {
    _fieldName :: Text
  , _fieldType :: ValType
  , _fieldVars :: [(Text, ValType)]
  } deriving (Eq, Ord, Show)

mappingOfFields :: [(StructField, ValType)] -> [(Text, ValType)] -> Maybe [FieldMapping]
mappingOfFields []     []  = pure []
mappingOfFields []     _   = Nothing
mappingOfFields (f:fs) vs0 = do
  (m,  vs1) <- mappingOfField  f  vs0
  ms        <- mappingOfFields fs vs1
  pure (m : ms)

mappingOfField :: (StructField, ValType) -> [(Text, ValType)] -> Maybe (FieldMapping, [(Text, ValType)])
mappingOfField (StructField fname, ftype) vars0 = do
  let go t (n, t')
       | t == t'   = Just (n, t)
       | otherwise = Nothing

  ns <- zipWithM go (meltType ftype) vars0

  let mapping = FieldMapping fname ftype ns
      vars1   = drop (length ns) vars0

  return (mapping, vars1)

------------------------------------------------------------------------

-- * Output

cond :: Doc -> Doc -> Doc
cond n body
 = vsep ["if (" <> n <> ")"
        , "{"
        , indent 4 body
        , "}"]

pair :: Doc -> Doc -> Doc
pair x y
 = vsep [ outputChar '['
        , x
        , outputChar ','
        , y
        , outputChar ']'
        ]

outputValue :: Doc -> [Doc] -> Doc
outputValue typ vals
 = vsep
 [ "error = psv_output_" <> typ <> " "
   <> "(fd, buffer, buffer_end, &buffer_ptr, " <> val <> ");"
 , outputDie
 ]
 where
  val = hcat (punctuate ", " vals)

forStmt :: Doc -> Doc -> Doc -> Doc
forStmt i n m
 = "for(iint_t" <+> i <+> "= 0," <+> n <+> "=" <+> m <> ";" <+> i <+> "<" <+> n <> "; ++" <> i <> ")"

outputChar :: Char -> Doc
outputChar x
 = outputValue "char" [seaOfChar x]

outputString :: Text -> Doc
outputString xs
 = vsep
 [ "if (buffer_end - buffer_ptr < " <> int rounded <> ") {"
 , "    error = psv_output_flush (fd, buffer, &buffer_ptr);"
 , indent 4 outputDie
 , "}"
 , vsep (fmap mkdoc swords)
 , "buffer_ptr += " <> int size <> ";"
 ]
 where
  swords = wordsOfString xs

  rounded  = length swords * 8
  size     = sum (fmap swSize swords)
  mkdoc sw = "*(uint64_t *)(buffer_ptr + " <> int (swOffset sw) <> ") = " <> swBits sw <> ";"

timeFmt :: Doc
timeFmt = "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld"

outputDie :: Doc
outputDie = "if (error) return error;"

seaOfWriteFleetOutput :: PsvMode -> [SeaProgramState] -> Either SeaError Doc
seaOfWriteFleetOutput mode states = do
  write_sea <- traverse seaOfWriteProgramOutput states
  pure $ vsep
    [ "#line 1 \"write all outputs\""
    , "static ierror_msg_t psv_write_outputs (int fd, const char *entity, size_t entity_size, ifleet_t *fleet)"
    , "{"
    , "    iint_t         chord_count = fleet->chord_count;"
    , "    const itime_t *chord_times = fleet->chord_times;"
    , "    ierror_msg_t   error;"
    , "    char           buffer[psv_output_buf_size];"
    , "    char          *buffer_end = buffer + psv_output_buf_size - 1;"
    , "    char          *buffer_ptr = buffer;"
    , ""
    , "    for (iint_t chord_ix = 0; chord_ix < chord_count; chord_ix++) {"
    , indent 8 (seaOfChordTime mode)
    , ""
    , indent 8 (vsep write_sea)
    , "    }"
    , ""
    , "    error = psv_output_flush (fd, buffer, &buffer_ptr);"
    , indent 4 outputDie
    , ""
    , "    return 0;"
    , "}"
    ]

seaOfChordTime :: PsvMode -> Doc
seaOfChordTime = \case
  PsvSnapshot _ -> vsep
    [ "const char  *chord_time = \"\";"
    , "const size_t chord_size = 0;"
    ]
  PsvChords     -> vsep
    [ "iint_t c_year, c_month, c_day, c_hour, c_minute, c_second;"
    , "itime_to_gregorian (chord_times[chord_ix], &c_year, &c_month, &c_day, &c_hour, &c_minute, &c_second);"
    , ""
    , "const size_t chord_size = sizeof (\"|yyyy-mm-ddThh:mm:ssZ\");"
    , "char chord_time[chord_size];"
    , "snprintf (chord_time, chord_size, \"|" <> timeFmt <> "\", "
             <> "c_year, c_month, c_day, c_hour, c_minute, c_second);"
    ]

seaOfWriteProgramOutput :: SeaProgramState -> Either SeaError Doc
seaOfWriteProgramOutput state = do
  let ps    = "p" <> int (stateName state)
      stype = pretty (nameOfStateType state)
      pname = pretty (nameOfProgram state)

  let resumeables = fmap (\(n,_) -> ps <> "->" <> pretty (hasPrefix <> n) <+> "= ifalse;") (stateResumables state)
  outputs <- traverse (\(n,(t,ts)) -> seaOfWriteOutput ps n t ts 0) (stateOutputs state)

  pure $ vsep
    [ ""
    , "/* " <> seaOfAttributeDesc (stateAttribute state) <> " */"
    , stype <+> "*" <> ps <+> "=" <+> "&fleet->" <> pname <> "[chord_ix];"
    , pname <+> "(" <> ps <> ");"
    , ps <> "->new_count = 0;"
    , vsep resumeables
    , ""
    , vsep outputs
    ]

seaOfWriteOutput :: Doc -> OutputName -> ValType -> [ValType] -> Int -> Either SeaError Doc
seaOfWriteOutput ps oname@(OutputName name) otype0 ts0 ixStart
  = let members = List.take (length ts0) (fmap (\ix -> ps <> "->" <> seaOfNameIx name ix) [ixStart..])
    in case otype0 of
         -- Top-level Sum is a special case, to avoid allocating and printing if
         -- the whole computation is an error (e.g. tombstone)
         SumT ErrorT otype1
          | (ErrorT : ts1) <- ts0
          , (ne     : _)   <- members
          -> do (body, _, _) <- seaOfOutput False ps oname otype1 ts1 (ixStart+1) (const id)
                let body'     = go body
                pure $ cond (ne <> " == ierror_not_an_error") body'
         _
          -> do (body, _, _) <- seaOfOutput False ps oname otype0 ts0 ixStart (const id)
                return $ go body

  where
    before = vsep [ outputValue  "string" ["entity", "entity_size"]
                  , outputString ("|" <> name <> "|") ]

    after  = vsep [ outputValue  "string" ["chord_time", "chord_size"]
                  , outputChar   '\n' ]

    go str = vsep [before, str, after]

seaOfOutput
  :: Bool                          -- ^ whether to quote strings (MASSIVE HACK)
  -> Doc                           -- ^ struct
  -> OutputName
  -> ValType                       -- ^ output type
  -> [ValType]                     -- ^ types of arguments
  -> Int                           -- ^ struct index
  -> (ValType -> Doc -> Doc)       -- ^ apply this to struct members
  -> Either SeaError ( Doc         -- output statements for consumed arguments
                     , Int         -- where it's up to
                     , [ValType] ) -- unconsumed arguments
seaOfOutput q ps oname@(OutputName name) otype0 ts0 ixStart transform
  = case otype0 of
      ArrayT te
       | tes@(t':_) <- meltType te
       , length ts0 == length tes
       , (arr : _)  <- members
       -> do (body, ix, _) <- seaOfOutput True ps oname te tes ixStart (arrayIndex...transform)
             -- Special case for (ArrayT (ArrayT NotArrayThing)) as that is allowed in v0
             let ac         = arrayCount $ transform (ArrayT t') arr
             body'         <- seaOfOutputArray body ac
             let ts1        = List.drop (length tes) ts0
             return (body', ix, ts1)

      MapT tk tv
       | tks        <- meltType tk
       , tvs        <- meltType tv
       , length ts0 == length tks + length tvs
       , (arr: _)   <- members
       -> do (bk, ixk, _)   <- seaOfOutput True ps oname tk tks ixStart (arrayIndex...transform)
             (bv, ixv, ts)  <- seaOfOutput True ps oname tv tvs ixk     (arrayIndex...transform)
             body'          <- seaOfOutputArray (pair bk bv) (arrayCount arr)
             return (body', ixv, ts)

      OptionT otype1
       | (BoolT : ts1) <- ts0
       , (nb    : _)   <- members
       -> do (body, ix, ts) <- seaOfOutput q ps oname otype1 ts1 (ixStart+1) transform
             pure (cond nb body, ix, ts)

      PairT ta tb
       | tas <- meltType ta
       , tbs <- meltType tb
       -> do (ba, ixa, _)  <- seaOfOutput True ps oname ta tas ixStart transform
             (bb, ixb, ts) <- seaOfOutput True ps oname tb tbs ixa     transform
             return (pair ba bb, ixb, ts)

      SumT ErrorT otype1
       | (ErrorT : ts1) <- ts0
       , (ne     : _)   <- members
       -> do (body, ix, ts) <- seaOfOutput False ps oname otype1 ts1 (ixStart+1) transform
             pure (cond (ne <> " == ierror_not_an_error") body, ix, ts)
      _
       | (t  : ts) <- ts0
       , (mx : _)  <- members
       , mx'  <- transform t mx
       -> do d <- seaOfOutputBase' q t mx'
             pure (d, ixStart + 1, ts)

      _ -> Left unsupported

  where
   mismatch    = SeaOutputTypeMismatch oname otype0 ts0
   unsupported = SeaUnsupportedOutputType otype0

   members = List.take (length ts0) (fmap (\ix -> ps <> "->" <> seaOfNameIx name ix) [ixStart..])

   counter    = pretty name <> "_" <> pretty ixStart <> "_i"
   countLimit = pretty name <> "_" <> pretty ixStart <> "_n"

   arrayIndex t x
    = seaOfArrayIndex x counter t

   arrayCount x
    = "(" <> x <> ")" <> "->count"

   seaOfOutputBase' b
    = seaOfOutputBase b mismatch

   -- Output an array with pre-defined bodies
   seaOfOutputArray body numElems
    = pure (vsep [ outputChar '['
                 , forStmt counter countLimit numElems
                 , "{"
                 , indent 4
                     $ cond (counter <+> "> 0")
                            (outputChar ',')
                 , indent 4 body
                 , "}"
                 , outputChar ']'
                 ]
           )

-- | Output single types
seaOfOutputBase :: Bool -> SeaError -> ValType -> Doc -> Either SeaError Doc
seaOfOutputBase quoteStrings err t val
 = case t of
     BoolT
      -> pure
       $ vsep
           [ "if (" <> val <> ") {"
           , indent 4 $ outputString "true"
           , "} else {"
           , indent 4 $ outputString "false"
           , "}"
           ]
     IntT
      -> pure $ outputValue "int" [val]
     DoubleT
      -> pure $ outputValue "double" [val]
     StringT
      -> pure $ quotedOutput quoteStrings (outputValue "string" [val, "strlen(" <> val <> ")"])
     TimeT
      -> pure $ quotedOutput quoteStrings (outputValue "time" [val])

     _ -> Left err

quotedOutput :: Bool -> Doc -> Doc
quotedOutput False out = out
quotedOutput True  out = vsep [outputChar '"', out, outputChar '"']

------------------------------------------------------------------------

sizeOfString :: Text -> Int
sizeOfString = B.length . T.encodeUtf8

seaOfStringEq :: Text -> Doc -> Maybe Doc -> Doc
seaOfStringEq str ptr msize
 | Just size <- msize
 , nbytes == 0        = size <+> "== 0"
 | Just size <- msize = align (vsep [szdoc size, cmpdoc])
 | otherwise          = align cmpdoc
 where
   nbytes = length bytes
   bytes  = B.unpack (T.encodeUtf8 str)

   szdoc size = size <+> "==" <+> int nbytes <+> "&&"
   cmpdoc     = seaOfBytesEq bytes ptr

seaOfBytesEq :: [Word8] -> Doc -> Doc
seaOfBytesEq bs ptr
 = vsep . punctuate " &&" . fmap go $ wordsOfBytes bs
 where
   go (StringWord off _ mask bits)
    = "(*(uint64_t *)(" <> ptr <+> "+" <+> int off <> ") &" <+> mask <> ") ==" <+> bits

------------------------------------------------------------------------

data StringWord = StringWord {
    swOffset :: Int
  , swSize   :: Int
  , swMask   :: Doc
  , swBits   :: Doc
  }

wordsOfString :: Text -> [StringWord]
wordsOfString
 = wordsOfBytes . B.unpack . T.encodeUtf8

wordsOfBytes :: [Word8] -> [StringWord]
wordsOfBytes bs
 = reverse (wordsOfBytes' bs 0 [])

wordsOfBytes' :: [Word8] -> Int -> [StringWord] -> [StringWord]
wordsOfBytes' [] _   acc = acc
wordsOfBytes' bs off acc
 = wordsOfBytes' remains (off + 8) (sw : acc)
 where
  sw = StringWord { swOffset = off, swSize = nbytes, swMask = mask, swBits = bits }

  (bytes, remains) = splitAt 8 bs

  nbytes = length bytes

  nzeros = 8 - nbytes
  zeros  = List.replicate nzeros 0x00

  mask = text $ "0x" <> concatMap (printf "%02X") (zeros <> List.replicate nbytes 0xff)
  bits = text $ "0x" <> concatMap (printf "%02X") (zeros <> reverse bytes)

------------------------------------------------------------------------

lookupTombstones :: PsvConfig -> SeaProgramState -> Set Text
lookupTombstones config state =
  fromMaybe Set.empty (Map.lookup (stateAttribute state) (psvTombstones config))

------------------------------------------------------------------------
-- Should be in P?

last :: [a] -> Maybe a
last []     = Nothing
last (x:[]) = Just x
last (_:xs) = last xs

init :: [a] -> Maybe [a]
init []     = Nothing
init (_:[]) = Just []
init (x:xs) = (x:) <$> init xs

(...) :: (a -> b -> b) -> (a -> b -> b) -> (a -> b -> b)
f ... g = \x y -> g x (f x y)
