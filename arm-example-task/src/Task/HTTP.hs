{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
module Task.HTTP where

import Arm.Core
import Arm.Wai
import Data.Aeson hiding (decode, encode)
import qualified Data.Aeson as JSON
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Network.HTTP.Types (hContentType, status200)
import Network.Wai
import Task.Domain
import Task.SQL
import Text.Read (readMaybe)

-- All GETs need only the query interpreter: no write authority is supplied.
taskObservations :: (forall a. DBQuery a -> IO (Either ApiError a)) -> [WaiRoute]
taskObservations runQuery =
  [ observationRouteWith (queryRequest ["projectId"]) jsonResponse domainErrorBoundary runQuery openTasks
  , observationRouteWith (queryRequest ["projectId"]) jsonResponse domainErrorBoundary runQuery projectTaskState
  , observationRouteWith (queryRequest ["assigneeId"]) jsonResponse domainErrorBoundary runQuery assigneeInbox ]

taskTransitions :: (forall a. DBQuery a -> IO (Either ApiError a))
  -> (forall a. DBCommand a -> IO (Either ApiError a)) -> [WaiRoute]
taskTransitions runQuery runCommand =
  [ transitionRouteWith bodyRequest jsonResponse domainErrorBoundary runQuery runCommand createTask
  , transitionRouteWith bodyRequest jsonResponse domainErrorBoundary runQuery runCommand closeTaskEndpoint
  , transitionRouteWith bodyRequest jsonResponse domainErrorBoundary runQuery runCommand assignTaskEndpoint ]

openTasks :: Observation OpenTasksInput ObservationContext DomainError [OpenTaskProjection]
openTasks = Observation
  { name = EndpointName "open-tasks"
  , decode = decodeJSON (withObject "open-tasks" (\o -> OpenTasksInput <$> optionalProject o "projectId"))
  , buildQuery = openTasksQuery, observe = observeOpenTasks
  , encode = encodeJSON (\items -> object ["openTasks" .= map openTaskJSON items]) }

projectTaskState :: Observation ProjectTaskStateInput ObservationContext DomainError ProjectTaskState
projectTaskState = Observation
  { name = EndpointName "project-task-state"
  , decode = decodeJSON (withObject "project-task-state" (\o -> ProjectTaskStateInput . ProjectId <$> positiveId o "projectId"))
  , buildQuery = projectTaskStateQuery, observe = observeProjectTaskState
  , encode = encodeJSON (\state -> object ["projectId" .= unProjectId (stateProject state), "open" .= openCount state, "closed" .= closedCount state]) }

assigneeInbox :: Observation AssigneeInboxInput ObservationContext DomainError [InboxItem]
assigneeInbox = Observation
  { name = EndpointName "assignee-inbox"
  , decode = decodeJSON (withObject "assignee-inbox" (\o -> AssigneeInboxInput . UserId <$> positiveId o "assigneeId"))
  , buildQuery = assigneeInboxQuery, observe = observeAssigneeInbox
  , encode = encodeJSON (\items -> object ["inbox" .= map inboxJSON items]) }

createTask :: Transition CreateTaskInput CreateTaskContext DomainError CreateTaskDelta CreateTaskResult CreateTaskResult
createTask = Transition
  { name = EndpointName "create-task"
  , decode = decodeJSON (withObject "create-task" $ \o -> do
      onlyKeys ["title", "projectId", "actorId", "assigneeId"] o
      CreateTaskInput <$> o .: "title" <*> (ProjectId <$> positiveId o "projectId")
        <*> (UserId <$> positiveId o "actorId") <*> optionalAssignee o "assigneeId")
  , buildQuery = createTaskQuery, decide = decideCreateTaskDelta
  , buildCommand = dbCommandFromDelta createTaskCommand, respond = \_ -> Right
  , encode = encodeJSON (\result -> object ["createdTaskId" .= unTaskId (createdTask result)]) }

closeTaskEndpoint :: Transition CloseTaskInput TaskContext DomainError CloseTaskDelta CloseTaskResult CloseTaskResult
closeTaskEndpoint = Transition
  { name = EndpointName "close-task"
  , decode = decodeJSON (withObject "close-task" $ \o -> do
      onlyKeys ["taskId"] o
      CloseTaskInput . TaskId <$> positiveId o "taskId")
  , buildQuery = taskContextQuery . closeTaskArgument, decide = decideCloseTaskDelta
  , buildCommand = dbCommandFromDelta closeTaskCommand, respond = \_ -> Right
  , encode = encodeJSON (\result -> object ["closedTaskId" .= unTaskId (closedTask result), "status" .= ("closed" :: String), "version" .= closedVersion result]) }

assignTaskEndpoint :: Transition AssignTaskInput TaskContext DomainError AssignTaskDelta AssignTaskResult AssignTaskResult
assignTaskEndpoint = Transition
  { name = EndpointName "assign-task"
  , decode = decodeJSON (withObject "assign-task" $ \o -> do
      onlyKeys ["taskId", "assigneeId"] o
      _ <- o .: "assigneeId" :: Parser Value
      AssignTaskInput <$> (TaskId <$> positiveId o "taskId") <*> optionalAssignee o "assigneeId")
  , buildQuery = taskContextQuery . assignTaskArgument, decide = decideAssignTaskDelta
  , buildCommand = dbCommandFromDelta assignTaskCommand, respond = \_ -> Right
  , encode = encodeJSON (\result -> object ["assignedTaskId" .= unTaskId (assignedTask result), "assigneeId" .= fmap unUserId (assignedUser result), "version" .= assignedVersion result]) }

positiveId :: Object -> Key -> Parser Integer
positiveId o key = do
  value <- o .: key
  if validId value then pure value else fail (Key.toString key <> " must fit a positive PostgreSQL bigint")
optionalAssignee :: Object -> Key -> Parser (Maybe UserId)
optionalAssignee o key = do
  value <- o .:? key
  case value of
    Nothing -> pure Nothing
    Just number | validId number -> pure (Just (UserId number))
                | otherwise -> fail (Key.toString key <> " must be a positive integer")
optionalProject :: Object -> Key -> Parser (Maybe ProjectId)
optionalProject o key = fmap (ProjectId . unUserId) <$> optionalAssignee o key
onlyKeys :: [Key] -> Object -> Parser ()
onlyKeys allowed o
  | all (`elem` allowed) (KeyMap.keys o) = pure ()
  | otherwise = fail "unknown input fields; supply only external operation arguments"

decodeJSON :: (Value -> Parser a) -> RawRequest -> Either ApiError a
decodeJSON parser (RawRequest body) = case eitherDecodeStrict' (Text.encodeUtf8 (Text.pack body)) >>= parseEither parser of
  Left message -> Left (ApiError ApiParseError message)
  Right input -> Right input
encodeJSON :: (a -> Value) -> a -> Either ApiError RawResponse
encodeJSON project = Right . RawResponse . Text.unpack . Text.decodeUtf8 . LBS.toStrict . JSON.encode . project

openTaskJSON :: OpenTaskProjection -> Value
openTaskJSON item = object
  [ "taskId" .= unTaskId (openTaskId item), "title" .= openTitle item
  , "projectId" .= unProjectId (openProject item), "assigneeId" .= fmap unUserId (openAssignee item) ]
inboxJSON :: InboxItem -> Value
inboxJSON item = object ["taskId" .= unTaskId (inboxTask item), "title" .= inboxTitle item, "projectId" .= unProjectId (inboxProject item)]

queryRequest :: [BS.ByteString] -> Request -> IO (Either ApiError RawRequest)
queryRequest allowed request = pure $ do
  let parameters = queryString request
  if any (\(key, _) -> key `notElem` allowed) parameters || length parameters /= length (unique (map fst parameters))
    then Left (ApiError ApiParseError "unknown or repeated query parameter")
    else do
      entries <- traverse parameter parameters
      (\(RawResponse body) -> RawRequest body) <$> encodeJSON id (Object (KeyMap.fromList entries))
  where
    unique [] = []
    unique (x:xs) = x : unique (filter (/= x) xs)
    parameter (key, value) = case (Text.decodeUtf8' key, value >>= either (const Nothing) Just . Text.decodeUtf8') of
      (Right keyText, Just text) -> case readMaybe (Text.unpack text) :: Maybe Integer of
        Just number | validId number -> Right (Key.fromText keyText, toJSON number)
        _ -> Left (ApiError ApiParseError "query IDs must be positive integers")
      _ -> Left (ApiError ApiParseError "query parameters require UTF-8 values")

validId :: Integer -> Bool
validId number = number > 0 && number <= 9223372036854775807

bodyRequest :: Request -> IO (Either ApiError RawRequest)
bodyRequest request = do
  bytes <- strictRequestBody request
  pure $ case Text.decodeUtf8' (LBS.toStrict bytes) of
    Left _ -> Left (ApiError ApiParseError "JSON body must be UTF-8")
    Right body -> Right (RawRequest (Text.unpack body))
jsonResponse :: Either ApiError RawResponse -> Response
jsonResponse result = case result of
  Right (RawResponse body) -> responseLBS status200 headers (LBS.fromStrict (Text.encodeUtf8 (Text.pack body)))
  Left err -> responseLBS (apiErrorStatus err) headers (JSON.encode (object
    ["error" .= object ["kind" .= show (apiErrorKind err), "message" .= apiErrorMessage err]]))
  where headers = [(hContentType, "application/json; charset=utf-8")]

domainErrorBoundary :: DomainErrorBoundary DomainError
domainErrorBoundary err = case err of
  InvalidTitle -> ApiError ApiValidationError "title must contain 1 to 200 non-padding characters"
  ProjectMissing -> ApiError ApiNotFoundError "project does not exist"
  UserMissing -> ApiError ApiNotFoundError "user does not exist"
  TaskMissing -> ApiError ApiNotFoundError "task does not exist"
  TaskAlreadyClosed -> ApiError ApiConflictError "task is already closed"
  ActorNotMember -> ApiError ApiValidationError "creator must be a project member"
  AssigneeNotMember -> ApiError ApiValidationError "assignee must be a project member"
  AssigneeUnchanged -> ApiError ApiConflictError "assignee mapping is unchanged"
