-- Pure domain algebra. No ARM, HTTP, JSON, SQL or database imports.
module Task.Domain where

import Data.Char (isSpace)
import Data.Set (Set)
import qualified Data.Set as Set

newtype UserId = UserId { unUserId :: Integer } deriving (Eq, Ord, Show)
newtype ProjectId = ProjectId { unProjectId :: Integer } deriving (Eq, Ord, Show)
newtype TaskId = TaskId { unTaskId :: Integer } deriving (Eq, Ord, Show)
data Status = Open | Closed deriving (Eq, Ord, Show)

-- One fact combines the total mappings defined on Task, with optional assignee.
data TaskFact = TaskFact
  { taskId :: TaskId, taskTitle :: String, taskProject :: ProjectId
  , taskStatus :: Status, taskAssignee :: Maybe UserId, taskVersion :: Integer
  } deriving (Eq, Show)

data DomainError
  = InvalidTitle | ProjectMissing | UserMissing | TaskMissing | TaskAlreadyClosed
  | ActorNotMember | AssigneeNotMember | AssigneeUnchanged
  deriving (Eq, Show)

-- Only external arguments. Status, generated identity and clock are absent.
data CreateTaskInput = CreateTaskInput
  { titleArgument :: String, projectArgument :: ProjectId
  , actorArgument :: UserId, assigneeArgument :: Maybe UserId
  } deriving (Eq, Show)
newtype CloseTaskInput = CloseTaskInput { closeTaskArgument :: TaskId }
  deriving (Eq, Show)
data AssignTaskInput = AssignTaskInput
  { assignTaskArgument :: TaskId, assignUserArgument :: Maybe UserId }
  deriving (Eq, Show)

data CreateTaskContext = CreateTaskContext
  { creationProjectExists :: Bool, creationActorExists :: Bool
  , creationMembers :: Set UserId, creationTime :: String
  } deriving (Eq, Show)
data TaskContext = TaskContext
  { currentTask :: Maybe TaskFact, currentMembers :: Set UserId, contextTime :: String }
  deriving (Eq, Show)

-- Add a fresh Task and its required title/project/status/creator/time mappings
-- together. The SQL interpreter binds the fresh identifier.
data CreateTaskDelta = CreateTaskDelta
  { addTitle :: String, addProject :: ProjectId, addCreator :: UserId
  , addCreatedAt :: String, addAssignee :: Maybe UserId, addStatus :: Status }
  deriving (Eq, Show)
-- Replace status Open -> Closed and add closedAt in one delta.
data CloseTaskDelta = CloseTaskDelta
  { closeTask :: TaskId, closeExpectedVersion :: Integer, addClosedAt :: String }
  deriving (Eq, Show)
-- Replace/remove the optional assignee mapping; never replace a persisted row.
data AssignTaskDelta = AssignTaskDelta
  { assignTask :: TaskId, assignExpectedVersion :: Integer, replaceAssignee :: Maybe UserId }
  deriving (Eq, Show)

decideCreateTaskDelta :: CreateTaskContext -> CreateTaskInput -> Either DomainError CreateTaskDelta
decideCreateTaskDelta context input
  | null trimmed || length trimmed > 200 = Left InvalidTitle
  | not (creationProjectExists context) = Left ProjectMissing
  | not (creationActorExists context) = Left UserMissing
  | Set.notMember (actorArgument input) (creationMembers context) = Left ActorNotMember
  | maybe False (`Set.notMember` creationMembers context) (assigneeArgument input) = Left AssigneeNotMember
  | otherwise = Right CreateTaskDelta
      { addTitle = trimmed, addProject = projectArgument input
      , addCreator = actorArgument input, addCreatedAt = creationTime context
      , addAssignee = assigneeArgument input, addStatus = Open }
  where trimmed = reverse (dropWhile isSpace (reverse (dropWhile isSpace (titleArgument input))))

openTask :: TaskContext -> TaskId -> Either DomainError TaskFact
openTask context requested = case currentTask context of
  Nothing -> Left TaskMissing
  Just fact | taskId fact /= requested -> Left TaskMissing
            | taskStatus fact == Closed -> Left TaskAlreadyClosed
            | otherwise -> Right fact

decideCloseTaskDelta :: TaskContext -> CloseTaskInput -> Either DomainError CloseTaskDelta
decideCloseTaskDelta context input = do
  fact <- openTask context (closeTaskArgument input)
  Right (CloseTaskDelta (taskId fact) (taskVersion fact) (contextTime context))

decideAssignTaskDelta :: TaskContext -> AssignTaskInput -> Either DomainError AssignTaskDelta
decideAssignTaskDelta context input = do
  fact <- openTask context (assignTaskArgument input)
  if maybe False (`Set.notMember` currentMembers context) target then Left AssigneeNotMember
  else if target == taskAssignee fact then Left AssigneeUnchanged
  else Right (AssignTaskDelta (taskId fact) (taskVersion fact) target)
  where target = assignUserArgument input

newtype OpenTasksInput = OpenTasksInput { openProjectArgument :: Maybe ProjectId } deriving (Eq, Show)
newtype ProjectTaskStateInput = ProjectTaskStateInput { stateProjectArgument :: ProjectId } deriving (Eq, Show)
newtype AssigneeInboxInput = AssigneeInboxInput { inboxUserArgument :: UserId } deriving (Eq, Show)
data ObservationContext = ObservationContext
  { observationSubjectExists :: Bool, taskFacts :: [TaskFact] } deriving (Eq, Show)
data OpenTaskProjection = OpenTaskProjection
  { openTaskId :: TaskId, openTitle :: String, openProject :: ProjectId, openAssignee :: Maybe UserId }
  deriving (Eq, Show)
data ProjectTaskState = ProjectTaskState
  { stateProject :: ProjectId, openCount :: Int, closedCount :: Int } deriving (Eq, Show)
data InboxItem = InboxItem
  { inboxTask :: TaskId, inboxTitle :: String, inboxProject :: ProjectId } deriving (Eq, Show)

observeOpenTasks :: ObservationContext -> OpenTasksInput -> Either DomainError [OpenTaskProjection]
observeOpenTasks context input
  | not (observationSubjectExists context) = Left ProjectMissing
  | otherwise = Right
      [ OpenTaskProjection (taskId t) (taskTitle t) (taskProject t) (taskAssignee t)
      | t <- taskFacts context, taskStatus t == Open
      , maybe True (== taskProject t) (openProjectArgument input) ]

observeProjectTaskState :: ObservationContext -> ProjectTaskStateInput -> Either DomainError ProjectTaskState
observeProjectTaskState context input
  | not (observationSubjectExists context) = Left ProjectMissing
  | otherwise = Right (ProjectTaskState project (count Open) (count Closed))
  where
    project = stateProjectArgument input
    count status = length [() | t <- taskFacts context, taskProject t == project, taskStatus t == status]

observeAssigneeInbox :: ObservationContext -> AssigneeInboxInput -> Either DomainError [InboxItem]
observeAssigneeInbox context input
  | not (observationSubjectExists context) = Left UserMissing
  | otherwise = Right
      [ InboxItem (taskId t) (taskTitle t) (taskProject t)
      | t <- taskFacts context, taskStatus t == Open, taskAssignee t == Just (inboxUserArgument input) ]

newtype CreateTaskResult = CreateTaskResult { createdTask :: TaskId } deriving (Eq, Show)
data CloseTaskResult = CloseTaskResult { closedTask :: TaskId, closedVersion :: Integer } deriving (Eq, Show)
data AssignTaskResult = AssignTaskResult
  { assignedTask :: TaskId, assignedUser :: Maybe UserId, assignedVersion :: Integer } deriving (Eq, Show)
