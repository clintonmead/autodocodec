{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-dodgy-exports -fno-warn-duplicate-exports #-}

module Autodocodec.Nix
  ( -- * Producing a Nixos module type
    renderNixOptionTypeViaCodec,
    renderNixOptionsViaCodec,
    renderNixOptionTypeVia,
    renderNixOptionsVia,
    valueCodecNixOptionType,
    objectCodecNixOptions,
    Option (..),
    OptionType (..),
    renderOption,
    renderOptionType,
    optionExpr,
    optionsExpr,
    optionTypeExpr,
    renderExpr,

    -- * To makes sure we definitely export everything.
    module Autodocodec.Nix,
  )
where

import Autodocodec
import Control.Applicative
import Data.Aeson as JSON
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Containers.ListUtils
import qualified Data.HashMap.Strict as HM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Scientific
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

renderNixOptionTypeViaCodec :: forall a. (HasCodec a) => Text
renderNixOptionTypeViaCodec = renderNixOptionTypeVia (codec @a)

renderNixOptionsViaCodec :: forall a. (HasObjectCodec a) => Text
renderNixOptionsViaCodec = renderNixOptionsVia (objectCodec @a)

renderNixOptionTypeVia :: ValueCodec input output -> Text
renderNixOptionTypeVia =
  renderOptionType
    . fromMaybe (OptionTypeSimple "lib.types.anything")
    . valueCodecNixOptionType

renderNixOptionsVia :: ObjectCodec input output -> Text
renderNixOptionsVia =
  renderOptions
    . objectCodecNixOptions

valueCodecNixOptionType :: ValueCodec input output -> Maybe OptionType
valueCodecNixOptionType = fmap simplifyOptionType . go
  where
    mTyp = fromMaybe $ OptionTypeSimple "lib.types.anything"
    go :: ValueCodec input output -> Maybe OptionType
    go = \case
      NullCodec -> Just OptionTypeNull
      BoolCodec _ -> Just $ OptionTypeSimple "lib.types.bool"
      StringCodec _ -> Just $ OptionTypeSimple "lib.types.str"
      IntegerCodec _ bounds -> Just $
        OptionTypeSimple $
          case guessIntegerBoundsSymbolic bounds of
            BitUInt w -> case w of
              64 -> "lib.types.ints.unsigned"
              32 -> "lib.types.ints.u32"
              16 -> "lib.types.ints.u16"
              8 -> "lib.types.ints.u8"
              _ -> "lib.types.int" -- TODO bounds?
            BitSInt w -> case w of
              64 -> "lib.types.int"
              32 -> "lib.types.ints.s32"
              16 -> "lib.types.ints.s16"
              8 -> "lib.types.ints.s8"
              _ -> "lib.types.int" -- TODO bounds?
            OtherIntegerBounds _ _ -> "lib.types.int" -- TODO bounds?
      NumberCodec _ _ -> Just $ OptionTypeSimple "lib.types.number"
      HashMapCodec c -> Just $ OptionTypeAttrsOf $ mTyp $ go c
      MapCodec c -> Just $ OptionTypeAttrsOf $ mTyp $ go c
      ValueCodec -> Just (OptionTypeSimple "lib.types.unspecified")
      ArrayOfCodec _ c -> Just $ OptionTypeListOf $ mTyp $ go c
      ObjectOfCodec _ oc -> Just (OptionTypeSubmodule (objectCodecNixOptions oc))
      EqCodec v c -> Just $ OptionTypeEnum [jsonValueExpr $ toJSONVia c v]
      BimapCodec _ _ c -> go c
      EitherCodec _ c1 c2 -> Just $ OptionTypeOneOf (map mTyp [go c1, go c2])
      CommentCodec _ c -> go c
      ReferenceCodec {} -> Nothing -- TODO: let-binding?

-- [tag:NixOptionNullable]
-- Note about nullable options:
-- It's not technically accurate to represent optional fields as the 'null' value in Nix,
-- but Nix isn't very good at optional values at all, so we use 'null' for both
-- optional fields and nullable fields.
-- If Nix options ever figure out how to do optional fields, we'll use that
-- instead.
objectCodecNixOptions :: ObjectCodec input output -> Map Text Option
objectCodecNixOptions = simplifyOptions . go False
  where
    -- The bool means 'force optional'
    go :: Bool -> ObjectCodec input output -> Map Text Option
    go b = \case
      DiscriminatedUnionCodec k _ m ->
        M.insert
          k
          ( Option
              { optionType = Just $ OptionTypeOneOf $ map (OptionTypeSimple . T.pack . show) $ HM.keys m,
                optionDescription = Nothing,
                optionDefault = Nothing
              }
          )
          $ M.unionsWith
            ( \t1 t2 ->
                Option
                  { optionType = Just $ OptionTypeOneOf $ map (fromMaybe (OptionTypeSimple "lib.types.anything") . optionType) [t1, t2],
                    optionDescription = optionDescription t1 <|> optionDescription t2, -- TODO
                    optionDefault = Nothing
                  }
            )
          $ map (go b . snd)
          $ HM.elems m
      RequiredKeyCodec key o mDesc ->
        M.singleton key $
          Option
            { optionType =
                ( if b
                    then fmap OptionTypeNullOr
                    else id
                )
                  $ valueCodecNixOptionType o,
              optionDescription = mDesc,
              optionDefault =
                if b
                  then Just JSON.Null
                  else Nothing -- [ref:NixOptionNullable]
            }
      OptionalKeyCodec key o mDesc ->
        M.singleton key $
          Option
            { optionType = OptionTypeNullOr <$> valueCodecNixOptionType o,
              optionDescription = mDesc,
              optionDefault = Just JSON.Null -- [ref:NixOptionNullable]
            }
      OptionalKeyWithDefaultCodec key c defaultValue mDesc ->
        M.singleton
          key
          Option
            { optionType = valueCodecNixOptionType c,
              optionDescription = mDesc,
              optionDefault = Just $ toJSONVia c defaultValue
            }
      OptionalKeyWithOmittedDefaultCodec key c defaultValue mDesc ->
        M.singleton
          key
          Option
            { optionType = valueCodecNixOptionType c,
              optionDescription = mDesc,
              optionDefault = Just $ toJSONVia c defaultValue
            }
      PureCodec _ -> M.empty
      ApCodec c1 c2 -> M.unionWith mergeOption (go b c1) (go b c2)
      BimapCodec _ _ c -> go b c
      EitherCodec _ c1 c2 -> M.unionWith mergeOption (go True c1) (go True c2)
    -- This throwing away of the description and the default is not ideal but
    -- better than just taking the first option.
    mergeOption :: Option -> Option -> Option
    mergeOption o1 o2 =
      o1
        { optionType =
            ( \ot1 ot2 ->
                simplifyOptionType $
                  OptionTypeOneOf
                    [ ot1,
                      ot2
                    ]
            )
              <$> optionType o1
              <*> optionType o2
        }

data Option = Option
  { optionType :: !(Maybe OptionType),
    optionDescription :: !(Maybe Text),
    optionDefault :: !(Maybe JSON.Value)
  }
  deriving (Show, Eq, Ord)

emptyOption :: Option
emptyOption =
  Option
    { optionType = Nothing,
      optionDescription = Nothing,
      optionDefault = Nothing
    }

simplifyOption :: Option -> Option
simplifyOption o = o {optionType = simplifyOptionType <$> optionType o}

data OptionType
  = OptionTypeNull
  | OptionTypeSimple !Text
  | OptionTypeEnum ![Expr]
  | OptionTypeNullOr !OptionType
  | OptionTypeListOf !OptionType
  | OptionTypeAttrsOf !OptionType
  | OptionTypeOneOf ![OptionType]
  | OptionTypeSubmodule !(Map Text Option)
  deriving (Show, Eq, Ord)

simplifyOptionType :: OptionType -> OptionType
simplifyOptionType = go
  where
    go = \case
      OptionTypeNull -> OptionTypeNull
      OptionTypeSimple t -> OptionTypeSimple t
      OptionTypeEnum es -> OptionTypeEnum es
      OptionTypeNullOr t -> case t of
        OptionTypeNull -> OptionTypeNull
        OptionTypeNullOr t' -> go $ OptionTypeNullOr t'
        OptionTypeOneOf os -> OptionTypeNullOr $ go $ OptionTypeOneOf $ filter (/= OptionTypeNull) $ map go os
        _ -> OptionTypeNullOr $ go t
      OptionTypeListOf o -> OptionTypeListOf $ go o
      OptionTypeAttrsOf o -> OptionTypeAttrsOf $ go o
      OptionTypeOneOf os -> case goEnums $ nubOrd $ concatMap goOr os of
        [ot] -> ot
        os' ->
          if any canBeNull os'
            then go $ OptionTypeNullOr $ case mapMaybe stripNull os' of
              [t] -> t
              ts' -> OptionTypeOneOf ts'
            else OptionTypeOneOf os'
      OptionTypeSubmodule m -> OptionTypeSubmodule $ M.map goOpt m

    canBeNull :: OptionType -> Bool
    canBeNull = \case
      OptionTypeNull -> True
      OptionTypeNullOr _ -> True
      _ -> False

    stripNull :: OptionType -> Maybe OptionType
    stripNull = \case
      OptionTypeNull -> Nothing
      OptionTypeNullOr t -> Just t
      t -> Just t

    goEnums :: [OptionType] -> [OptionType]
    goEnums = goEnum []
      where
        goEnum :: [Expr] -> [OptionType] -> [OptionType]
        goEnum es = \case
          [] -> case es of
            [] -> []
            _ -> [OptionTypeEnum es]
          (t : rest) -> case t of
            OptionTypeEnum es' -> goEnum (es ++ es') rest
            _ -> t : goEnum es rest

    goOpt o = o {optionType = go <$> optionType o}

    goOr = \case
      OptionTypeOneOf os -> concatMap goOr os
      o -> [o]

simplifyOptions :: Map Text Option -> Map Text Option
simplifyOptions = M.map simplifyOption

renderOption :: Option -> Text
renderOption = renderExpr . withNixArgs . optionExpr

renderOptions :: Map Text Option -> Text
renderOptions = renderExpr . withNixArgs . optionsExpr

renderOptionType :: OptionType -> Text
renderOptionType = renderExpr . withNixArgs . optionTypeExpr

withNixArgs :: Expr -> Expr
withNixArgs = ExprFun ["lib"]

optionExpr :: Option -> Expr
optionExpr Option {..} =
  ExprAp
    (ExprVar "lib.mkOption")
    ( ExprAttrSet $
        M.fromList $
          concat
            [ [("type", optionTypeExpr typ) | typ <- maybeToList optionType],
              [("description", ExprLitString d) | d <- maybeToList optionDescription],
              case optionDefault of
                Nothing -> case optionType of
                  -- Automatically give submodule options a default of the empty set.
                  Just (OptionTypeSubmodule _) -> [("default", ExprAttrSet M.empty)]
                  _ -> []
                Just d -> [("default", jsonValueExpr d)]
            ]
    )

optionsExpr :: Map Text Option -> Expr
optionsExpr = ExprAttrSet . M.map optionExpr

optionTypeExpr :: OptionType -> Expr
optionTypeExpr = go
  where
    go = \case
      OptionTypeNull -> ExprAp (ExprVar "lib.types.enum") (ExprLitList [ExprNull])
      OptionTypeSimple s -> ExprVar s
      OptionTypeEnum es -> ExprAp (ExprVar "lib.types.enum") (ExprLitList es)
      OptionTypeNullOr ot -> ExprAp (ExprVar "lib.types.nullOr") (go ot)
      OptionTypeListOf ot ->
        ExprAp
          (ExprVar "lib.types.listOf")
          (go ot)
      OptionTypeAttrsOf ot ->
        ExprAp
          (ExprVar "lib.types.attrsOf")
          (go ot)
      OptionTypeOneOf os ->
        ExprAp
          (ExprVar "lib.types.oneOf")
          (ExprLitList (map go os))
      OptionTypeSubmodule os ->
        ExprAp
          (ExprVar "lib.types.submodule")
          (ExprAttrSet (M.singleton "options" (optionsExpr os)))

jsonValueExpr :: JSON.Value -> Expr
jsonValueExpr = \case
  JSON.Null -> ExprNull
  JSON.Bool b -> ExprLitBool b
  JSON.String s -> ExprLitString s
  JSON.Number n -> ExprLitNumber n
  JSON.Array v -> ExprLitList $ map jsonValueExpr $ V.toList v
  JSON.Object vs -> ExprAttrSet $ M.mapKeysMonotonic Key.toText $ KeyMap.toMap $ KeyMap.map jsonValueExpr vs

data Expr
  = ExprNull
  | ExprLitBool !Bool
  | ExprLitString !Text
  | ExprLitNumber !Scientific
  | ExprLitList ![Expr]
  | ExprVar !Text
  | ExprAttrSet !(Map Text Expr)
  | ExprAp !Expr !Expr
  | ExprFun ![Text] !Expr
  | ExprWith !Text !Expr
  deriving (Show, Eq, Ord)

renderExpr :: Expr -> Text
renderExpr = T.unlines . go 0
  where
    parensWhen b ts = if b then parens ts else ts
    go :: Int -> Expr -> [Text]
    go d = \case
      ExprNull -> ["null"]
      ExprLitBool b -> [if b then "true" else "false"]
      ExprLitString s -> [T.pack $ show $ T.unpack s]
      ExprLitNumber s ->
        [ case floatingOrInteger s of
            Left f -> T.pack $ show (f :: Double)
            Right i -> T.pack $ show (i :: Integer)
        ]
      ExprLitList es -> case es of
        [] -> ["[]"]
        [e] -> surround "[" "]" $ go 0 e
        _ ->
          -- If there is more than one list element, put them on separate lines.
          "[" : indent (concatMap (go 11) es) ++ ["]"]
      ExprVar s -> [s]
      ExprAttrSet m | null m -> ["{ }"]
      ExprAttrSet m ->
        -- We always put "{" and "}" on separate lines.
        "{" : indent (concatMap (uncurry goBind) (M.toList m)) ++ ["}"]
      ExprAp e1 e2 ->
        parensWhen (d > 10) $
          go 11 e1 `apply` go 11 e2
      ExprFun args e ->
        parensWhen (d > 10) $
          surroundWith " " "{" "}:" [T.intercalate ", " args]
            ++ go 0 e
      ExprWith t e ->
        parensWhen (d > 10) $
          ("with " <> t <> ";") : go 0 e
    goBind key e =
      prependWith " " (key <> " =") $
        (`append` ";") $
          go 0 e

indent :: [Text] -> [Text]
indent = map ("  " <>)

prepend :: Text -> [Text] -> [Text]
prepend = prependWith T.empty

prependWith :: Text -> Text -> [Text] -> [Text]
prependWith spacer t = \case
  [] -> [t]
  (u : us) -> (t <> spacer <> u) : us

append :: [Text] -> Text -> [Text]
append = appendWith T.empty

appendWith :: Text -> [Text] -> Text -> [Text]
appendWith spacer ts u = go ts
  where
    go = \case
      [] -> [u]
      [t] -> [t <> spacer <> u]
      (t : ts') -> t : go ts'

apply :: [Text] -> [Text] -> [Text]
apply ts1 ts2 = case (ts1, ts2) of
  ([t1], [t2]) -> [t1 <> " " <> t2]
  ([t1], _) -> prependWith " " t1 ts2
  (_, [t2]) -> ts1 `append` t2
  _ -> go ts1
    where
      go = \case
        [] -> ts2
        [t] -> prependWith " " t ts2
        (t : ts) -> t : go ts

parens :: [Text] -> [Text]
parens = surround "(" ")"

surround :: Text -> Text -> [Text] -> [Text]
surround = surroundWith T.empty

surroundWith :: Text -> Text -> Text -> [Text] -> [Text]
surroundWith spacer open close = prependWith spacer open . (\t -> appendWith spacer t close)
