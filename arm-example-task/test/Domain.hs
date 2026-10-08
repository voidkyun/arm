module Main (main) where

import qualified Data.Set as Set
import Task.Domain
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "pure task algebra"
  [ testCase "creation adds every required mapping and a valid optional relation" $
      decideCreateTaskDelta creation input @?= Right (CreateTaskDelta "Review" (ProjectId 1) (UserId 1) now (Just (UserId 2)) Open)
  , testCase "creation without assignee" $
      fmap addAssignee (decideCreateTaskDelta creation (input {assigneeArgument = Nothing})) @?= Right Nothing
  , testCase "empty title" $ decideCreateTaskDelta creation (input {titleArgument = " \n\t "}) @?= Left InvalidTitle
  , testCase "overlong title" $ decideCreateTaskDelta creation (input {titleArgument = replicate 201 'x'}) @?= Left InvalidTitle
  , testCase "PostgreSQL text cannot represent embedded NUL" $ decideCreateTaskDelta creation (input {titleArgument = "review\0task"}) @?= Left InvalidTitle
  , testCase "maximum title" $ fmap (length . addTitle) (decideCreateTaskDelta creation (input {titleArgument = replicate 200 'x'})) @?= Right 200
  , testCase "missing project" $ decideCreateTaskDelta (creation {creationProjectExists = False}) input @?= Left ProjectMissing
  , testCase "missing creator" $ decideCreateTaskDelta (creation {creationActorExists = False}) input @?= Left UserMissing
  , testCase "creator outside membership" $ decideCreateTaskDelta creation (input {actorArgument = UserId 3}) @?= Left ActorNotMember
  , testCase "assignee outside membership" $ decideCreateTaskDelta creation (input {assigneeArgument = Just (UserId 3)}) @?= Left AssigneeNotMember
  , testCase "close replaces status with a timestamp and expected version" $
      decideCloseTaskDelta context (CloseTaskInput (TaskId 1)) @?= Right (CloseTaskDelta (TaskId 1) 7 now)
  , testCase "cannot close missing task" $ decideCloseTaskDelta missing (CloseTaskInput (TaskId 1)) @?= Left TaskMissing
  , testCase "cannot close different task context" $ decideCloseTaskDelta context (CloseTaskInput (TaskId 2)) @?= Left TaskMissing
  , testCase "cannot close closed task" $ decideCloseTaskDelta closed (CloseTaskInput (TaskId 1)) @?= Left TaskAlreadyClosed
  , testCase "assign replaces mapping" $ decideAssignTaskDelta context (AssignTaskInput (TaskId 1) (Just (UserId 1))) @?= Right (AssignTaskDelta (TaskId 1) 7 (Just (UserId 1)))
  , testCase "unassign removes mapping" $ decideAssignTaskDelta context (AssignTaskInput (TaskId 1) Nothing) @?= Right (AssignTaskDelta (TaskId 1) 7 Nothing)
  , testCase "unchanged assignee" $ decideAssignTaskDelta context (AssignTaskInput (TaskId 1) (Just (UserId 2))) @?= Left AssigneeUnchanged
  , testCase "invalid assignee" $ decideAssignTaskDelta context (AssignTaskInput (TaskId 1) (Just (UserId 3))) @?= Left AssigneeNotMember
  , testCase "assign missing task" $ decideAssignTaskDelta missing (AssignTaskInput (TaskId 1) Nothing) @?= Left TaskMissing
  , testCase "assign closed task" $ decideAssignTaskDelta closed (AssignTaskInput (TaskId 1) Nothing) @?= Left TaskAlreadyClosed
  , testCase "open tasks filters status and project" $ observeOpenTasks observations (OpenTasksInput (Just (ProjectId 1))) @?= Right [OpenTaskProjection (TaskId 1) "Review" (ProjectId 1) (Just (UserId 2))]
  , testCase "project state is a status projection" $ observeProjectTaskState observations (ProjectTaskStateInput (ProjectId 1)) @?= Right (ProjectTaskState (ProjectId 1) 1 1)
  , testCase "inbox only contains open tasks of selected assignee" $ observeAssigneeInbox observations (AssigneeInboxInput (UserId 2)) @?= Right [InboxItem (TaskId 1) "Review" (ProjectId 1)]
  , testCase "empty existing project" $ observeProjectTaskState (ObservationContext True []) (ProjectTaskStateInput (ProjectId 1)) @?= Right (ProjectTaskState (ProjectId 1) 0 0)
  , testCase "missing observation project" $ observeOpenTasks (ObservationContext False []) (OpenTasksInput (Just (ProjectId 1))) @?= Left ProjectMissing
  , testCase "missing observation user" $ observeAssigneeInbox (ObservationContext False []) (AssigneeInboxInput (UserId 2)) @?= Left UserMissing
  , testProperty "every valid creation preserves membership and required mappings" $ \(Positive n) ->
      let title = replicate (1 + n `mod` 200) 'x' in case decideCreateTaskDelta creation (input {titleArgument = title}) of
        Right delta -> addTitle delta == title && addStatus delta == Open && addProject delta == ProjectId 1
          && addCreator delta `Set.member` creationMembers creation && maybe True (`Set.member` creationMembers creation) (addAssignee delta)
        Left _ -> False
  , testProperty "all overlong titles reject without a delta" $ \(Positive n) ->
      decideCreateTaskDelta creation (input {titleArgument = replicate (201 + n `mod` 300) 'x'}) == Left InvalidTitle
  ]

now :: String
now = "2026-10-08T12:00:00Z"
creation :: CreateTaskContext
creation = CreateTaskContext True True (Set.fromList [UserId 1, UserId 2]) now
input :: CreateTaskInput
input = CreateTaskInput "  Review  " (ProjectId 1) (UserId 1) (Just (UserId 2))
fact :: TaskFact
fact = TaskFact (TaskId 1) "Review" (ProjectId 1) Open (Just (UserId 2)) 7
context, missing, closed :: TaskContext
context = TaskContext (Just fact) (Set.fromList [UserId 1, UserId 2]) now
missing = context {currentTask = Nothing}
closed = context {currentTask = Just (fact {taskStatus = Closed})}
observations :: ObservationContext
observations = ObservationContext True [fact, fact {taskId = TaskId 2, taskStatus = Closed}, fact {taskId = TaskId 3, taskProject = ProjectId 2, taskAssignee = Just (UserId 1)}]
