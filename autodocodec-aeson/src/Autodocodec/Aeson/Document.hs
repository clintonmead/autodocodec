{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Autodocodec.Aeson.Document where

import Autodocodec
import Autodocodec.Aeson.Encode
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as JSON
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe
import Data.Text (Text)
import GHC.Generics (Generic)

-- TODO think about putting this value in a separate package or directly in autodocodec
--
-- http://json-schema.org/understanding-json-schema/reference/index.html
data JSONSchema
  = AnySchema
  | NullSchema
  | BoolSchema
  | StringSchema
  | NumberSchema
  | ArraySchema !JSONSchema
  | ObjectSchema !JSONObjectSchema
  | ValueSchema !JSON.Value
  | ChoiceSchema ![JSONSchema]
  | CommentSchema !Text !JSONSchema
  deriving (Show, Eq, Generic)

data JSONObjectSchema
  = AnyObjectSchema
  | KeySchema !KeyRequirement !Text !JSONSchema
  | BothObjectSchema !JSONObjectSchema !JSONObjectSchema
  deriving (Show, Eq, Generic)

data KeyRequirement = Required | Optional
  deriving (Show, Eq, Generic)

instance ToJSON JSONSchema where
  toJSON = JSON.object . go
    where
      go = \case
        AnySchema -> []
        NullSchema -> ["type" JSON..= ("null" :: Text)]
        BoolSchema -> ["type" JSON..= ("boolean" :: Text)]
        StringSchema -> ["type" JSON..= ("string" :: Text)]
        NumberSchema -> ["type" JSON..= ("number" :: Text)]
        ArraySchema s -> ["type" JSON..= ("array" :: Text), "items" JSON..= s]
        ValueSchema v -> ["const" JSON..= v]
        ObjectSchema os ->
          let goO = \case
                AnyObjectSchema -> ([], [])
                KeySchema r k s ->
                  ( [(k, s)],
                    case r of
                      Required -> [k]
                      Optional -> []
                  )
                BothObjectSchema os1 os2 ->
                  let (ps1, rps1) = goO os1
                      (ps2, rps2) = goO os2
                   in (ps1 ++ ps2, rps1 ++ rps2)
           in case goO os of
                ([], _) -> ["type" JSON..= ("object" :: Text)]
                (ps, []) ->
                  [ "type" JSON..= ("object" :: Text),
                    "properties" JSON..= ps
                  ]
                (ps, rps) ->
                  [ "type" JSON..= ("object" :: Text),
                    "properties" JSON..= ps,
                    "required" JSON..= rps
                  ]
        ChoiceSchema jcs -> ["anyOf" JSON..= jcs]
        CommentSchema comment s -> ("$comment" JSON..= comment) : go s -- TODO this is probably wrong.

instance FromJSON JSONSchema where
  parseJSON = JSON.withObject "JSONSchema" $ \o -> do
    mt <- o JSON..:? "type"
    mc <- o JSON..:? "$comment"
    let commentFunc = maybe id CommentSchema mc
    fmap commentFunc $ case mt :: Maybe Text of
      Just "null" -> pure NullSchema
      Just "boolean" -> pure BoolSchema
      Just "string" -> pure StringSchema
      Just "number" -> pure NumberSchema
      Just "array" -> do
        mI <- o JSON..:? "items"
        case mI of
          Nothing -> pure $ ArraySchema AnySchema
          Just is -> pure $ ArraySchema is
      Just "object" -> do
        mP <- o JSON..: "properties"
        case mP of
          Nothing -> pure $ ObjectSchema AnyObjectSchema
          Just props -> do
            requiredProps <- fromMaybe [] <$> o JSON..:? "required"
            -- TODO distinguish between required and optional properties
            let keySchemas =
                  map
                    ( \(k, s) ->
                        KeySchema
                          ( if k `elem` requiredProps
                              then Required
                              else Optional
                          )
                          k
                          s
                    )
                    props
            let go (ks :| rest) = case NE.nonEmpty rest of
                  Nothing -> ks
                  Just ne -> BothObjectSchema ks (go ne)
            pure $
              ObjectSchema $ case NE.nonEmpty keySchemas of
                Nothing -> AnyObjectSchema
                Just ne -> go ne
      Nothing -> do
        mAny <- o JSON..:? "anyOf"
        case mAny of
          Just anies -> pure $ ChoiceSchema anies
          Nothing -> do
            mConst <- o JSON..:? "const"
            case mConst of
              Just constant -> pure $ ValueSchema constant
              Nothing -> fail "Unknown object schema without type, anyOf or const."
      t -> fail $ "unknown schema type:" <> show t

jsonSchemaViaCodec :: forall a. HasCodec a => JSONSchema
jsonSchemaViaCodec = jsonSchemaVia (codec @a)

jsonSchemaVia :: Codec input output -> JSONSchema
jsonSchemaVia = go
  where
    go :: Codec input output -> JSONSchema
    go = \case
      NullCodec -> NullSchema
      BoolCodec -> BoolSchema
      StringCodec -> StringSchema
      NumberCodec -> NumberSchema
      ArrayCodec mname c -> maybe id CommentSchema mname $ ArraySchema (go c)
      ObjectCodec mname oc -> maybe id CommentSchema mname $ ObjectSchema (goObject oc)
      EqCodec value c -> ValueSchema (toJSONVia c value)
      BimapCodec _ _ c -> go c
      EitherCodec c1 c2 -> ChoiceSchema (goChoice [go c1, go c2])
      ExtraParserCodec _ _ c -> go c
      CommentCodec t c -> CommentSchema t (go c)

    goChoice :: [JSONSchema] -> [JSONSchema]
    goChoice = concatMap goSingle
      where
        goSingle :: JSONSchema -> [JSONSchema]
        goSingle = \case
          ChoiceSchema ss -> goChoice ss
          s -> [s]

    goObject :: ObjectCodec input output -> JSONObjectSchema
    goObject = \case
      RequiredKeyCodec k c -> KeySchema Required k (go c)
      OptionalKeyCodec k c -> KeySchema Optional k (go c)
      BimapObjectCodec _ _ oc -> goObject oc
      PureObjectCodec _ -> AnyObjectSchema
      ApObjectCodec oc1 oc2 -> BothObjectSchema (goObject oc1) (goObject oc2)
