/**
 * AI Arena core debate state machine.
 *
 * `createSession` and `applyAction` never mutate the session they receive.
 * They return the next session (or throw a validation error). The only
 * external input is the clock used for `updatedAt`.
 *
 * Public session fields:
 *   {
 *     id, question, providers, stage, round, paused,
 *     tasks, history, guidance, report?, updatedAt
 *   }
 * `stopReason` is an optional, additional field written when a debate ends.
 *
 * `guidance` holds user conditions added while the discussion is paused. A
 * note is recorded with the stage, round, source and time it was written and
 * is appended only to tasks constructed afterwards (independent, critique and
 * proposal). Already pending, archived or vote prompts are never rewritten,
 * so a vote still covers exactly the candidate text it was issued for.
 *
 * `tasks` only ever contains the current stage. Completed or skipped tasks
 * are copied into `history` with their stage and round; history entries are
 * never rewritten.
 *
 * A manual public seat may correct its saved answer in place during the
 * current independent or critique round, but only while another seat in that
 * round is still pending. The correction keeps `originalAnswer`, `answeredAt`,
 * `correctedAt` and the replaced texts in `corrections`; it never creates a
 * second answer or changes a prompt that was already issued.
 *
 * Stages:
 *   independent -> critique -> proposal -> vote -> done
 * A vote that does not settle the discussion runs one more targeted critique
 * round, a revised candidate and a fresh vote on that candidate version.
 * The budget is `maxRounds` (1-5), the number of review cycles. Independent
 * answers are a prerequisite stage before the first cycle and are not counted
 * by the budget. Each cycle starts with critique, then a candidate (or a
 * revised candidate) and a stance on that exact text. The shared engine's
 * default is 2, including for sessions saved before the budget existed.
 * The native desktop app creates a new discussion with an explicit 3, so its
 * visible default is three review cycles unless the user picks another budget
 * (1-5). A session created without an explicit budget keeps the original
 * behaviour: explicit opposition gets one follow-up round and conditional
 * agreement stops immediately. A new desktop session states a budget
 * explicitly and also follows unresolved conditions. At the limit the session
 * stops with the remaining opposition or conditions reported verbatim.
 *
 * Frozen material is embedded verbatim: a long answer is never shortened in
 * the middle, so a unique objection in the middle of a peer answer still
 * reaches the other seat and the vote.
 *
 * A full-consensus ending additionally requires every provider to have
 * supplied an independent answer and a cross-review answer for the current
 * round. A candidate with no verifiable [S#] reference ends as a marked draft
 * even when every seat clicked agree.
 */

import { LOCAL_AUTOMATION_PROVIDER_IDS, PUBLIC_AUTOMATION_PROVIDER_IDS } from './providers.js';

const STANCES = ['agree', 'conditional', 'oppose'];
const PROVIDER_ID_RE = /^[a-z0-9]+(?:[-_][a-z0-9]+)*$/;

/**
 * Seats a session may hold. Two is the tested default; three is the supported
 * ceiling for a real multi-model run. Every stage, prompt and report iterates
 * `session.providers`, so a third seat is shared with all peers and must vote
 * on the same candidate version like any other seat.
 *
 * Exported for the worker and for tests. UI code should not import the whole
 * state machine just for these numbers; keep its own copy or move them to a
 * tiny shared constant module.
 */
export const MIN_SEATS = 2;
export const MAX_SEATS = 3;

// Maximum number of review cycles. Independent answers are a prerequisite
// stage and are not part of the budget. `DEFAULT_MAX_ROUNDS` is the
// legacy/shared-engine budget: two cycles, one targeted follow-up for explicit
// opposition only, which sessions saved before the option retain. The native desktop app passes 3 explicitly for a new
// discussion (its UI label is 互评上限); an explicit budget also follows
// unresolved conditions. Each cycle starts with critique, then candidate and
// stance.
export const MIN_ROUNDS = 1;
export const MAX_ROUNDS = 5;
export const DEFAULT_MAX_ROUNDS = 2;

// A manually relayed answer may be corrected only inside the round it belongs
// to, and only while another seat in that same round is still pending. Once
// the round completes, its prompts are frozen and a correction would silently
// change material another seat already received.
const CORRECTABLE_STAGES = new Set(['independent', 'critique']);
const LOCAL_AUTOMATION_SEATS = new Set(LOCAL_AUTOMATION_PROVIDER_IDS);
export const PUBLIC_WEB_VOTE_FORMAT = [
  '',
  '',
  '【网页表态格式】',
  '正文说明理由，最后一行只写一个立场标记：STANCE: agree、STANCE: conditional 或 STANCE: oppose。',
].join('\n');

// Where a paused user may add a condition, and which newly constructed task
// prompts carry it. Vote prompts are excluded on purpose: a vote must stay on
// the exact candidate text it was issued for.
const GUIDANCE_INPUT_STAGES = new Set(['independent', 'critique']);
const GUIDANCE_TASK_STAGES = new Set(['independent', 'critique', 'proposal']);
const MAX_GUIDANCE = 2000;

const STAGE_LABELS = {
  independent: '独立作答',
  critique: '互评',
  proposal: '候选结论',
  vote: '表态',
  done: '结束',
};

const STANCE_LABELS = {
  agree: '同意',
  conditional: '有条件同意',
  oppose: '反对',
};

function normalizeMaxRounds(options) {
  const raw =
    typeof options === 'number'
      ? options
      : options && typeof options === 'object' && !Array.isArray(options)
        ? options.maxRounds
        : undefined;
  if (raw === undefined || raw === null) return DEFAULT_MAX_ROUNDS;
  if (
    !Number.isInteger(raw) ||
    raw < MIN_ROUNDS ||
    raw > MAX_ROUNDS
  ) {
    throw new Error(
      `maxRounds must be an integer between ${MIN_ROUNDS} and ${MAX_ROUNDS}`,
    );
  }
  return raw;
}

/**
 * A caller that names a round budget is an explicit new-session choice (the
 * desktop workbench). Such a session follows unresolved conditions while
 * rounds remain. The extension and every session saved before this option
 * existed keep the original conditional-stop behaviour.
 */
function hasExplicitRoundBudget(options) {
  return (
    typeof options === 'number' ||
    Boolean(
      options &&
        typeof options === 'object' &&
        options.maxRounds !== undefined &&
        options.maxRounds !== null,
    )
  );
}

function sessionMaxRounds(session) {
  const raw = Number(session?.maxRounds);
  if (
    Number.isInteger(raw) &&
    raw >= MIN_ROUNDS &&
    raw <= MAX_ROUNDS
  ) {
    return raw;
  }
  // Sessions saved before the round budget existed had exactly two rounds.
  return DEFAULT_MAX_ROUNDS;
}

/**
 * Create the initial, independent-answer stage for two or three distinct
 * canonical lowercase provider ids. The same opening prompt goes to every
 * seat; nothing here assumes exactly two participants.
 *
 * `options` may be a number or `{ maxRounds }`. Omitting it keeps the original
 * two-round budget, so the extension's call site and every saved session keep
 * working unchanged.
 */
export function createSession(question, providers, options) {
  if (typeof question !== 'string' || question.trim().length === 0) {
    throw new Error('question must be a non-empty string');
  }
  if (
    !Array.isArray(providers) ||
    providers.length < MIN_SEATS ||
    providers.length > MAX_SEATS
  ) {
    throw new Error(
      `providers must contain ${MIN_SEATS} or ${MAX_SEATS} distinct provider ids, got ${
        Array.isArray(providers) ? providers.length : typeof providers
      }`,
    );
  }

  const seen = new Set();
  for (const provider of providers) {
    if (typeof provider !== 'string' || !PROVIDER_ID_RE.test(provider)) {
      throw new Error(
        `invalid provider id "${String(provider)}"; expected a canonical lowercase id`,
      );
    }
    if (seen.has(provider)) {
      throw new Error(`providers must be distinct; duplicate "${provider}"`);
    }
    seen.add(provider);
  }

  const session = {
    id: makeSessionId(),
    question,
    providers: providers.slice(),
    stage: 'independent',
    round: 1,
    maxRounds: normalizeMaxRounds(options),
    followConditions: hasExplicitRoundBudget(options),
    paused: false,
    tasks: [],
    history: [],
    guidance: [],
    updatedAt: Date.now(),
  };

  const attachments = options?.attachments ?? [];
  if (!Array.isArray(attachments)) throw new Error('附件清单无效');
  const opening = independentPrompt(question, attachments);
  if (attachments.length) {
    if (opening.length > 100000) throw new Error('题面与附件正文合计过长，请缩短后再开始');
    // Only the actual opening prompts keep inline file bodies. The manifest
    // is small and records the exact file identity independently of answers.
    session.attachments = attachments.map(({ text, ...metadata }) => metadata);
  }

  for (const provider of session.providers) {
    session.tasks.push(
      makeTask(
        session,
        'independent',
        session.round,
        provider,
        // R02: every seat must receive the exact same opening prompt.
        // Seat identity lives on the task/record, never in this text.
        opening,
      ),
    );
  }

  return session;
}

/**
 * Apply one user or coordinator action and return the next session.
 *
 * action:
 *   'answer'  payload { taskId, text, stance?, version?, stage?, round? }
 *   'correct' payload { taskId, text, previousText, stage?, round? }
 *   'skip'    payload { taskId }
 *   'guide'   payload { text }          (only while paused, independent/critique)
 *   'pause' | 'resume' | 'finish'
 */
export function applyAction(session, action, payload = {}) {
  assertSession(session);
  if (typeof action !== 'string') {
    throw new Error('action must be a string');
  }
  if (payload === null || payload === undefined) payload = {};
  if (typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('payload must be an object');
  }

  const next = clone(session);
  // Sessions saved before guidance existed have no field; treat them as empty.
  if (!Array.isArray(next.guidance)) next.guidance = [];

  if (action === 'pause') {
    if (session.stage === 'done' || next.paused) return next;
    next.paused = true;
    touch(next, session);
    return next;
  }

  if (action === 'resume') {
    if (session.stage === 'done') return next;
    const wasPaused = next.paused;
    const beforeStage = next.stage;
    const beforeTasks = next.tasks.length;
    next.paused = false;
    advanceWhilePossible(next);
    if (
      wasPaused ||
      next.stage !== beforeStage ||
      next.tasks.length !== beforeTasks
    ) {
      touch(next, session);
    }
    return next;
  }

  if (action === 'finish') {
    if (session.stage === 'done') return next;
    archiveTasks(next);
    finalize(next, 'user-finished');
    touch(next, session);
    return next;
  }

  if (action === 'answer') {
    if (session.stage === 'done') {
      throw new Error('session is done; no further answers are accepted');
    }
    actAnswer(next, payload);
    advanceWhilePossible(next);
    touch(next, session);
    return next;
  }

  if (action === 'attachmentReceipt') {
    const task = requireCurrentTask(next, payload.taskId);
    if (task.status !== 'pending') throw new Error('附件核对任务已经结束');
    recordAttachmentReceipt(next, task, payload.attachmentReceipt);
    touch(next, session);
    return next;
  }

  if (action === 'correct') {
    if (session.stage === 'done') {
      throw new Error('session is done; no further corrections are accepted');
    }
    // A correction replaces one saved answer in place. It never advances the
    // stage, never creates a second answer record and never rewrites a frozen
    // prompt, so the pending count is unchanged by design.
    actCorrect(next, payload);
    touch(next, session);
    return next;
  }

  if (action === 'skip') {
    if (session.stage === 'done') {
      throw new Error('session is done; no further actions are accepted');
    }
    actSkip(next, payload);
    advanceWhilePossible(next);
    touch(next, session);
    return next;
  }

  if (action === 'guide') {
    actGuide(next, payload);
    touch(next, session);
    return next;
  }

  throw new Error(`unknown action "${action}"`);
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

function recordAttachmentReceipt(session, task, receipt) {
  if (session.stage !== 'independent' || !task.attachmentIDs?.length ||
      (receipt !== 'verified' && receipt !== 'manual')) {
    throw new Error('附件核对记录无效');
  }
  // Keep a stronger, original-page receipt if a human later takes over.
  if (task.attachmentReceipt !== 'verified') task.attachmentReceipt = receipt;
}

function actAnswer(session, payload) {
  const task = requireCurrentTask(session, payload.taskId);

  if (task.status === 'answered') {
    throw new Error(`task "${task.id}" was already answered`);
  }
  if (task.status === 'skipped') {
    throw new Error(
      `task "${task.id}" was skipped; a late answer requires a new round`,
    );
  }

  // Optional coordinates let the UI reject an overdue reply before the text
  // is attached to the wrong stage/round.
  if (payload.stage !== undefined && payload.stage !== session.stage) {
    throw new Error(
      `stale submission: expected stage "${session.stage}", got "${String(payload.stage)}"`,
    );
  }
  if (payload.round !== undefined && payload.round !== session.round) {
    throw new Error(
      `stale submission: expected round ${session.round}, got ${String(payload.round)}`,
    );
  }

  const text = payload.text;
  if (typeof text !== 'string' || text.trim().length === 0) {
    throw new Error('answer text must be a non-empty string; incomplete replies are not accepted');
  }

  if (session.stage === 'proposal') {
    validateProposalReferences(session, text);
  }

  let stance;
  if (payload.stance !== undefined) {
    if (!STANCES.includes(payload.stance)) {
      throw new Error('stance must be "agree", "conditional", or "oppose"');
    }
    stance = payload.stance;
  }

  if (session.stage === 'vote') {
    if (!stance) {
      throw new Error(
        'vote answers require stance "agree", "conditional", or "oppose"',
      );
    }
    if (
      payload.version !== undefined &&
      payload.version !== task.version
    ) {
      throw new Error(
        `stale submission: vote is for candidate version ${task.version}, got ${String(payload.version)}`,
      );
    }
    const proposal = latestAnsweredProposal(session.history);
    if (!proposal || task.version !== proposal.version) {
      throw new Error(
        `stale submission: candidate version ${String(task.version)} is no longer current`,
      );
    }
    // Version alone is not enough: the vote must cover the exact whole text
    // that was put forward, not a summary, an excerpt, or a later edit that
    // kept the same version number.
    if (
      typeof task.proposalDigest !== 'string' ||
      task.proposalDigest !== proposalDigest(proposal)
    ) {
      throw new Error(
        `stale submission: the whole candidate v${task.version} text changed after this vote task was issued; re-read the current candidate and vote again`,
      );
    }
  }

  if (payload.attachmentReceipt !== undefined) {
    recordAttachmentReceipt(session, task, payload.attachmentReceipt);
  }
  if (task.attachmentIDs?.length && !['verified', 'manual'].includes(task.attachmentReceipt)) {
    throw new Error('请先核对本席收到的全部开场材料');
  }
  task.status = 'answered';
  task.answer = text;
  // Kept apart from any later correction: the submission time never changes
  // when the text is corrected in the same round.
  task.answeredAt = Math.max(Date.now(), Number(session.updatedAt) || 0);
  if (session.stage === 'vote') task.stance = stance;
}

/**
 * Replace one already saved answer in place.
 *
 * The caller must name the exact text it believes is saved (`previousText`).
 * A second window, a stale card or a repeated click then fails instead of
 * overwriting someone else's correction. Only this one task record changes;
 * the stage, every prompt and every other answer stay untouched. The first
 * submitted text is kept in `originalAnswer` and each replacement keeps the
 * text it replaced plus its own timestamp in `corrections`, so no answer is
 * counted twice and the original remains recoverable.
 */
function actCorrect(session, payload) {
  if (!CORRECTABLE_STAGES.has(session.stage)) {
    throw new Error(
      `answers cannot be corrected in the ${session.stage} stage; correcting is limited to current independent or critique rounds`,
    );
  }

  const task = requireCurrentTask(session, payload.taskId);

  if (LOCAL_AUTOMATION_SEATS.has(task.provider)) {
    throw new Error(
      `task "${task.id}" belongs to an automated seat; its saved answer is only changed by the seat's own reply`,
    );
  }
  if (task.status === 'skipped') {
    throw new Error(
      `task "${task.id}" was skipped; a skip is not a saved answer and cannot be corrected`,
    );
  }
  if (task.status !== 'answered') {
    throw new Error(
      `task "${task.id}" has no saved answer yet; submit the answer instead of correcting it`,
    );
  }

  // A correction is safe only while the rest of this round is still open. If
  // every other seat has answered (or skipped), the round has already frozen
  // and a later prompt may carry the text we are about to replace.
  const others = session.tasks.filter((candidate) => candidate.id !== task.id);
  if (!others.some((candidate) => candidate.status === 'pending')) {
    throw new Error(
      `this ${session.stage} round is already frozen: no other seat is still pending, so a correction would rewrite material already sent onward`,
    );
  }

  // Optional coordinates let a stale card fail before it touches the record.
  if (payload.stage !== undefined && payload.stage !== session.stage) {
    throw new Error(
      `stale correction: expected stage "${session.stage}", got "${String(payload.stage)}"`,
    );
  }
  if (payload.round !== undefined && payload.round !== session.round) {
    throw new Error(
      `stale correction: expected round ${session.round}, got "${String(payload.round)}"`,
    );
  }

  if (
    typeof payload.previousText !== 'string' ||
    payload.previousText !== task.answer
  ) {
    throw new Error(
      'stale correction: the saved answer is no longer the text this edit started from; reopen the latest saved answer and correct that',
    );
  }

  const text = payload.text;
  if (typeof text !== 'string' || text.trim().length === 0) {
    throw new Error(
      'corrected text must be a non-empty string; incomplete corrections are not accepted',
    );
  }
  if (text === task.answer) {
    throw new Error('the corrected text is identical to the saved answer; nothing was changed');
  }

  const at = Math.max(
    Date.now(),
    Number(task.answeredAt) || 0,
    Array.isArray(task.corrections) && task.corrections.length > 0
      ? Number(task.corrections[task.corrections.length - 1].at) || 0
      : 0,
  );

  // The first submitted text is never overwritten by a later correction.
  if (typeof task.originalAnswer !== 'string') task.originalAnswer = task.answer;
  if (!Array.isArray(task.corrections)) task.corrections = [];
  task.corrections.push({ previousText: task.answer, text, at });
  task.answer = text;
  task.correctedAt = at;
}

function actSkip(session, payload) {
  const task = requireCurrentTask(session, payload.taskId);
  if (task.status === 'answered') {
    throw new Error(`task "${task.id}" was already answered`);
  }
  if (task.status === 'skipped') {
    throw new Error(`task "${task.id}" was already skipped`);
  }
  task.status = 'skipped';
}

/**
 * Record a user condition without touching any prompt already issued. The note
 * carries immutable markers (where it was added, who wrote it, when); only
 * tasks constructed later pick it up through `makeTask`.
 */
function actGuide(session, payload) {
  if (!GUIDANCE_INPUT_STAGES.has(session.stage)) {
    throw new Error(
      `guidance is not accepted in the ${session.stage} stage; add a condition only during independent or critique, before a candidate or vote exists`,
    );
  }
  if (!session.paused) {
    throw new Error(
      'pause the discussion before adding a condition; a running round is not changed retroactively',
    );
  }

  const raw = payload.text;
  if (typeof raw !== 'string') {
    throw new Error('guidance text must be a string');
  }
  const text = raw.trim();
  if (text.length === 0) {
    throw new Error('guidance text must be a non-empty string');
  }
  if (text.length > MAX_GUIDANCE) {
    throw new Error(`guidance text must be at most ${MAX_GUIDANCE} characters`);
  }

  const notes = session.guidance;
  const seq =
    notes.reduce((max, note) => Math.max(max, Number(note.seq) || 0), 0) + 1;
  const lastAt = notes.length ? Number(notes[notes.length - 1].createdAt) || 0 : 0;
  notes.push({
    seq,
    text,
    // Immutable markers: later stages and rounds never rewrite them.
    stage: session.stage,
    round: session.round,
    source: 'user',
    createdAt: Math.max(Date.now(), lastAt + 1),
    // Bookkeeping only: filled with the tasks this condition was appended to.
    deliveredTo: [],
  });
}

function requireCurrentTask(session, taskId) {
  if (typeof taskId !== 'string' || taskId.trim().length === 0) {
    throw new Error('taskId is required');
  }

  const current = session.tasks.find((task) => task.id === taskId);
  if (current) return current;

  const past = session.history.find((task) => task.id === taskId);
  if (past) {
    if (past.status === 'skipped') {
      throw new Error(
        `stale submission: task "${taskId}" was skipped in ${past.stage} round ${past.round}; a late answer requires a new round`,
      );
    }
    throw new Error(
      `stale submission: task "${taskId}" belongs to ${past.stage} round ${past.round}; current stage is ${session.stage} round ${session.round}`,
    );
  }

  throw new Error(`unknown task "${taskId}"`);
}

// ---------------------------------------------------------------------------
// Stage transitions
// ---------------------------------------------------------------------------

function advanceWhilePossible(session) {
  let guard = 0;
  while (session.stage !== 'done' && !session.paused) {
    if (guard++ > 20) {
      throw new Error('stage transition did not settle');
    }
    if (session.tasks.length === 0) {
      // Defensive: a stage without tasks cannot make progress.
      finalize(session, 'no-tasks');
      return;
    }
    if (session.tasks.some((task) => task.status === 'pending')) return;
    advanceStage(session);
  }
}

function advanceStage(session) {
  const completedStage = session.stage;
  const completed = session.tasks;
  archiveTasks(session);

  switch (completedStage) {
    case 'independent':
      advanceFromIndependent(session, completed);
      return;
    case 'critique':
      advanceFromCritique(session);
      return;
    case 'proposal':
      advanceFromProposal(session);
      return;
    case 'vote':
      advanceFromVote(session);
      return;
    default:
      throw new Error(`cannot advance unknown stage "${completedStage}"`);
  }
}

function advanceFromIndependent(session, completed) {
  const eligible = session.providers.filter((provider) =>
    completed.some(
      (task) =>
        task.provider === provider &&
        task.status === 'answered' &&
        typeof task.answer === 'string' &&
        task.answer.trim().length > 0,
    ),
  );

  if (eligible.length === 0) {
    finalize(session, 'no-answers');
    return;
  }

  session.stage = 'critique';
  const independentAnswers = answeredHistory(session, 'independent');

  for (const provider of eligible) {
    const own = latestByProvider(independentAnswers, provider);
    const opponents = independentAnswers.filter(
      (task) => task.provider !== provider,
    );
    // A seat is absent only when it is missing from the eligible independent
    // answers. The recipient itself is not "missing" from its own opponent
    // list: in a fully attended round nothing is absent, whatever the seat count.
    const missing = session.providers.filter(
      (candidate) => !eligible.includes(candidate),
    );
    session.tasks.push(
      makeTask(
        session,
        'critique',
        session.round,
        provider,
        critiquePrompt(session.question, provider, own, opponents, missing),
      ),
    );
  }
}

function advanceFromCritique(session) {
  const critiqueAnswers = answeredHistory(session, 'critique').filter(
    (task) => task.round === session.round,
  );
  if (critiqueAnswers.length === 0) {
    finalize(session, 'no-critique');
    return;
  }

  const eligibleProviders = uniqueProviders(critiqueAnswers);
  const attempted = session.history
    .filter(
      (task) => task.stage === 'proposal' && task.round === session.round,
    )
    .map((task) => task.provider);
  const remaining = eligibleProviders.filter(
    (provider) => !attempted.includes(provider),
  );

  if (remaining.length === 0) {
    finalize(session, 'proposal-skipped');
    return;
  }

  const previous = latestAnsweredProposal(session.history);
  const preferred =
    previous && remaining.includes(previous.provider)
      ? previous.provider
      : remaining[0];

  issueProposal(session, preferred);
}

function advanceFromProposal(session) {
  const answered = session.history.filter(
    (task) =>
      task.stage === 'proposal' &&
      task.round === session.round &&
      task.status === 'answered' &&
      typeof task.answer === 'string' &&
      task.answer.trim().length > 0,
  );

  if (answered.length > 0) {
    const proposal = latestAnsweredProposal(session.history);
    issueVotes(session, proposal);
    return;
  }

  // The drafter skipped. Let another seat that supplied critique material
  // take over before declaring the report partial.
  const critiqueAnswers = answeredHistory(session, 'critique').filter(
    (task) => task.round === session.round,
  );
  const attempted = session.history
    .filter(
      (task) => task.stage === 'proposal' && task.round === session.round,
    )
    .map((task) => task.provider);
  const remaining = uniqueProviders(critiqueAnswers).filter(
    (provider) => !attempted.includes(provider),
  );

  if (remaining.length > 0) {
    issueProposal(session, remaining[0]);
    return;
  }

  finalize(session, 'proposal-skipped');
}

function advanceFromVote(session) {
  const proposal = latestAnsweredProposal(session.history);
  if (!proposal) {
    finalize(session, 'proposal-skipped');
    return;
  }

  const digest = proposalDigest(proposal);
  const votes = answeredHistory(session, 'vote').filter(
    (task) =>
      task.round === session.round &&
      STANCES.includes(task.stance) &&
      task.version === proposal.version &&
      task.proposalDigest === digest,
  );
  const anyOppose = votes.some((task) => task.stance === 'oppose');
  const anyConditional = votes.some(
    (task) => task.stance === 'conditional',
  );
  const allProvidersVoted = session.providers.every((provider) =>
    votes.some((task) => task.provider === provider),
  );
  const maxRounds = sessionMaxRounds(session);

  // A targeted follow-up is due for explicit opposition in every budget. A
  // conditional vote is only followed by a session that was explicitly given
  // a round budget (a new desktop session) and where every seat has voted;
  // older sessions and the extension keep the conditional-stop behaviour.
  const conditionalFollowUp =
    session.followConditions === true && allProvidersVoted && anyConditional;
  const needsFollowUp = anyOppose || conditionalFollowUp;

  if (needsFollowUp && session.round < maxRounds) {
    const concerns = votes.filter(
      (task) =>
        task.stance === 'oppose' ||
        (task.stance === 'conditional' && session.followConditions === true),
    );
    session.round += 1;
    session.stage = 'critique';
    for (const provider of session.providers) {
      session.tasks.push(
        makeTask(
          session,
          'critique',
          session.round,
          provider,
          targetedCritiquePrompt(
            session.question,
            provider,
            proposal,
            concerns,
          ),
        ),
      );
    }
    return;
  }

  if (anyOppose) {
    finalize(session, 'unresolved-opposition');
    return;
  }
  if (!allProvidersVoted) {
    finalize(session, 'partial-votes');
    return;
  }

  // A seat that never answered independently is absent from the discussion,
  // even if it can still click a vote. Its click cannot manufacture consensus.
  const missingIndependent = session.providers.filter(
    (provider) =>
      !session.history.some(
        (task) =>
          task.stage === 'independent' &&
          task.provider === provider &&
          isUsableAnswer(task),
      ),
  );
  if (missingIndependent.length > 0) {
    finalize(session, 'partial-participation');
    return;
  }

  // Receiving someone's text is not the same as cross-reviewing it. A full
  // consensus needs a usable critique answer from every seat in this round.
  const missingCrossReview = session.providers.filter(
    (provider) =>
      !session.history.some(
        (task) =>
          task.stage === 'critique' &&
          task.round === session.round &&
          task.provider === provider &&
          isUsableAnswer(task),
      ),
  );
  if (missingCrossReview.length > 0) {
    finalize(session, 'no-cross-review');
    return;
  }

  // No verifiable source means the result is a draft, not a validated
  // consensus — regardless of how many seats clicked agree.
  const citations = proposalCitationState(session, proposal);
  if (citations.valid.length === 0) {
    finalize(session, 'draft');
    return;
  }

  if (votes.every((task) => task.stance === 'agree')) {
    finalize(session, 'consensus');
    return;
  }
  finalize(session, 'conditional-agreement');
}

function issueProposal(session, provider) {
  const version = nextProposalVersion(session);
  const task = makeTask(
    session,
    'proposal',
    session.round,
    provider,
    proposalPrompt(session, provider, version),
  );
  task.version = version;
  session.stage = 'proposal';
  session.tasks.push(task);
}

function issueVotes(session, proposal) {
  if (!proposal) {
    finalize(session, 'proposal-skipped');
    return;
  }
  session.stage = 'vote';
  for (const provider of session.providers) {
    const task = makeTask(
      session,
      'vote',
      session.round,
      provider,
      votePrompt(session, provider, proposal),
    );
    task.version = proposal.version;
    task.proposalSourceId = proposal.sourceId;
    task.proposalDigest = proposalDigest(proposal);
    session.tasks.push(task);
  }
}

function finalize(session, reason) {
  session.stage = 'done';
  session.tasks = [];
  session.paused = false;
  session.stopReason = reason;
  session.report = buildReport(session, reason);
}

// ---------------------------------------------------------------------------
// Tasks and history
// ---------------------------------------------------------------------------

function makeTask(session, stage, round, provider, prompt) {
  const id = `${session.id}:r${round}:${stage}:${provider}`;
  // Guidance exists only from the moment it was saved: applying it here means
  // every task built afterwards carries it, while prompts already pending or
  // archived keep the exact text they were issued with.
  const notes =
    GUIDANCE_TASK_STAGES.has(stage) && Array.isArray(session.guidance)
      ? session.guidance.slice()
      : [];

  const task = {
    id,
    provider,
    prompt: notes.length > 0 ? appendGuidance(prompt, notes) : prompt,
    status: 'pending',
    sourceId: allocateSourceId(session),
  };

  if (stage === 'independent' && session.attachments?.length) {
    task.attachmentIDs = session.attachments.map((file) => file.id);
  }

  if (notes.length > 0) {
    task.guidanceSeqs = notes.map((note) => note.seq);
    for (const note of notes) {
      const delivered = Array.isArray(note.deliveredTo) ? note.deliveredTo : [];
      if (!delivered.includes(id)) delivered.push(id);
      note.deliveredTo = delivered;
    }
  }

  return task;
}

function appendGuidance(prompt, notes) {
  const lines = [
    '【用户补充条件】',
    '用户在讨论中追加了以下条件，必须作为判断输入考虑；这些是用户陈述，未经事实核验，也不代表其他席位已经接受。',
  ];
  for (const note of notes) {
    lines.push(
      `- #${note.seq}（${STAGE_LABELS[note.stage] ?? note.stage}第${note.round}轮提出）：${note.text}`,
    );
  }
  lines.push('如果其中某条改变了你的主张，请写明是第几条、改变了什么。');
  const block = lines.join('\n');

  // Keep the prompt's own opening (original question) and closing instructions
  // intact; the condition sits right after the question it qualifies.
  const split = prompt.indexOf('\n\n');
  if (split === -1) return `${prompt}\n\n${block}`;
  return `${prompt.slice(0, split + 2)}${block}\n\n${prompt.slice(split + 2)}`;
}

function allocateSourceId(session) {
  let max = 0;
  for (const task of [...session.history, ...session.tasks]) {
    const match = /^S(\d+)$/.exec(String(task.sourceId ?? ''));
    if (match) max = Math.max(max, Number(match[1]));
  }
  return `S${max + 1}`;
}

function archiveTasks(session) {
  for (const task of session.tasks) {
    session.history.push({
      ...task,
      stage: session.stage,
      round: session.round,
    });
  }
  session.tasks = [];
}

function answeredHistory(session, stage) {
  return session.history.filter(
    (task) =>
      task.stage === stage &&
      task.status === 'answered' &&
      typeof task.answer === 'string' &&
      task.answer.trim().length > 0,
  );
}

function uniqueProviders(tasks) {
  const seen = new Set();
  const providers = [];
  for (const task of tasks) {
    if (!seen.has(task.provider)) {
      seen.add(task.provider);
      providers.push(task.provider);
    }
  }
  return providers;
}

function latestByProvider(tasks, provider) {
  for (let index = tasks.length - 1; index >= 0; index -= 1) {
    if (tasks[index].provider === provider) return tasks[index];
  }
  return null;
}

export function latestAnsweredProposal(history) {
  const proposals = history.filter(
    (task) =>
      task.stage === 'proposal' &&
      task.status === 'answered' &&
      typeof task.answer === 'string' &&
      task.answer.trim().length > 0 &&
      Number.isInteger(task.version),
  );
  if (proposals.length === 0) return null;
  proposals.sort(
    (left, right) =>
      left.version - right.version || left.round - right.round,
  );
  return proposals[proposals.length - 1];
}

function nextProposalVersion(session) {
  const previous = latestAnsweredProposal(session.history);
  return previous ? previous.version + 1 : 1;
}

/**
 * Bind a vote to the exact candidate text, not just its version number.
 * A short, deterministic digest is enough to detect a summary/excerpt being
 * substituted for the full candidate, or a history entry that changed while
 * keeping the same version.
 */
export function proposalDigest(proposal) {
  const text = String(proposal?.answer ?? '');
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `${text.length}:${hash.toString(16).padStart(8, '0')}`;
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

function independentPrompt(question, attachments) {
  const materials = [];
  let imageNumber = 0;
  for (const file of attachments) {
    if (file.kind === 'image') {
      materials.push(`图 ${++imageNumber} · ${file.name}`);
    } else if (file.kind === 'text' && typeof file.text === 'string') {
      materials.push(`文本附件 · ${file.name}（以下为文件正文）\n${file.text}\n【文件正文结束】`);
    } else {
      throw new Error('附件格式无效');
    }
  }
  return [
    '【原始问题】',
    question,
    '',
    ...(materials.length ? ['【本场附件】', ...materials, ''] : []),
    '你是本次讨论的独立席位。这是独立作答轮，你看不到其他席位的回答，其他席位也看不到你的回答。',
    '请直接回答上面的问题，并写清：',
    '1. 你的明确判断与主要理由；',
    '2. 支撑判断的最强依据；',
    '3. 最可能推翻你的反例、适用条件，以及需要补充的事实；',
    '4. 如果证据不足，说明你在什么条件下愿意改变主张。',
    '',
    '不要假设其他席位已经同意任何结论；只输出你的回答。',
  ].join('\n');
}

function critiquePrompt(question, provider, own, opponents, missing) {
  const opponentBlocks =
    opponents.length > 0
      ? opponents.map(sourceBlock).join('\n\n')
      : '本轮没有其他席位提供可用的独立回答（对方缺席或跳过）。';

  const lines = [
    '【原始问题】',
    question,
    '',
    `你是席位「${provider}」。本轮是交叉质询：把对方文字当作带来源编号的数据，不要把收到文字当作同意。`,
    '',
    '【本方上一轮回答】',
    own ? sourceBlock(own) : '你没有可用的上一轮回答。',
    '',
    '【对方材料】',
    opponentBlocks,
  ];

  if (missing.length > 0) {
    lines.push('', `【缺席席位】${missing.join('、')}（缺席、跳过或超时都不能算作同意）`);
  }

  lines.push(
    '',
    '请完成：',
    '1. 指出对方最有分量的依据，以及其中最可能推翻你判断的反例；',
    '2. 明确回应这个反例：它是否成立、是否改变你的主张；',
    '3. 说明你维持或修正了哪条主张，以及适用的条件；',
    '4. 如果对方缺席，请对自己的判断做一次最强反驳；',
    '5. 引用材料时保留来源编号（如 S1、S2）。',
    '',
    '不要用礼貌性同意代替证据和推理。',
  );

  return lines.join('\n');
}

function proposalPrompt(session, provider, version) {
  const material = session.history.filter(
    (task) =>
      task.status === 'answered' &&
      typeof task.answer === 'string' &&
      task.answer.trim().length > 0,
  );

  return [
    '【原始问题】',
    session.question,
    '',
    '【冻结材料（带来源编号，按轮次保存）】',
    material.length > 0
      ? material.map(sourceBlock).join('\n\n')
      : '没有可用的回答材料。',
    '',
    '【起草任务】',
    `你是候选结论起草席位「${provider}」。请基于以上材料起草候选结论版本 v${version}，并输出 Markdown：`,
    '1. 先用一段话给出建议回答；',
    '2. 列出成立条件、最强反例、已解决与未解决的争点；',
    '3. 每个关键判断后用 [S#] 标注出处；',
    '4. 不得虚构来源，不得把缺席、跳过或未表态视为同意；',
    '5. 如果材料互相矛盾，保留分歧并说明哪条新事实能解决它。',
    '',
    '写作风格接近“80% of the way to ASD-STE100”。用自然清晰的中文，句子简短，术语一致，条件明确。',
    '只有在明显有助于理解时，才在正文里用简单图解或对照表。',
    '',
    '只输出候选结论正文。',
  ].join('\n');
}

function votePrompt(session, provider, proposal) {
  const previous = latestByProvider(
    session.history.filter(
      (task) =>
        task.stage === 'vote' &&
        task.status === 'answered' &&
        task.version !== proposal.version,
    ),
    provider,
  );

  const lines = [
    '【原始问题】',
    session.question,
    '',
    `【候选结论 · 版本 v${proposal.version} · 来源 ${proposal.sourceId}】`,
    '以下为本次表决的唯一候选结论全文。请对这份完整文本表态；不要依据摘要、往轮版本或对方的转述。',
    '',
    sourceBlock(proposal),
    '',
    `你是席位「${provider}」。请只针对同一候选版本 v${proposal.version} 的上述全文明确表态：`,
    '- agree：明确同意；',
    '- conditional：有条件同意，必须写出条件；',
    '- oppose：明确反对，必须写出反对点。',
    '',
    '在界面提交时选择对应 stance；正文说明理由。不要用礼貌性同意代替明确接受，也不要把缺席或沉默当作同意。',
  ];

  if (previous) {
    lines.push(
      '',
      `【你上一轮的表态（版本 v${previous.version}，仅供对照，不代表本轮态度）】`,
      sourceBlock(previous),
    );
  }

  const prompt = lines.join('\n');
  return PUBLIC_AUTOMATION_PROVIDER_IDS.includes(provider) ? prompt + PUBLIC_WEB_VOTE_FORMAT : prompt;
}

function targetedCritiquePrompt(question, provider, proposal, concerns) {
  const ownConcern = concerns.find((task) => task.provider === provider);
  const blocks =
    concerns.length > 0
      ? concerns.map(concernBlock).join('\n\n')
      : '没有记录到未解决的反对或附加条件。';

  const lines = [
    '【原始问题】',
    question,
    '',
    `你是席位「${provider}」。上一轮表决没有形成全体同意；本轮是定向质询，只处理未解决的分歧与条件（明确反对或有条件同意）。`,
    '',
    '【当前候选结论】',
    proposal ? sourceBlock(proposal) : '没有可用的候选结论。',
    '',
    '【未解决的分歧与条件（原文）】',
    blocks,
  ];

  if (ownConcern) {
    if (ownConcern.stance === 'oppose') {
      lines.push(
        '',
        '你上一轮明确选择了反对。请重新检验自己的反对理由，也明确说明什么证据会改变它。',
      );
    } else {
      lines.push(
        '',
        '你上一轮选择了有条件同意，并写明了条件。请重新检验该条件是否已被当前候选满足，也明确说明什么证据会让它变成无条件同意或明确反对。',
      );
    }
  }

  lines.push(
    '',
    '请完成：',
    '1. 逐条复述反对意见或附加条件的核心命题；',
    '2. 用材料中的证据判断每条是否成立，并直接回应；',
    '3. 明确说明你的主张或条件是否改变，以及改变所需的新事实；',
    '4. 如果仍无法解决，保留该反对或条件并说明原因；',
    '5. 引用材料时保留来源编号（如 S1、S2）。',
    '',
    '不要声称已经达成共识；也不要把“有条件同意”当作“反对”，或把未解决的条件当作已接受。只有每位席位对同一版本明确同意且没有附加条件才构成全体一致。',
  );

  return lines.join('\n');
}

function concernBlock(task) {
  return [
    `[${task.sourceId ?? 'S?'} · ${task.provider} · 表决 · 第${task.round}轮 · ${STANCE_LABELS[task.stance] ?? task.stance}]`,
    String(task.answer ?? ''),
  ].join('\n');
}

// Recover what each saved review actually received, including in older sessions
// without separate source metadata. Rebuild the prompt from frozen records so
// that citations quoted inside an answer cannot be mistaken for input sources.
export function reviewMaterials(session) {
  const independent = answeredHistory(session, 'independent');
  const missing = session.providers.filter((provider) => !latestByProvider(independent, provider));
  const reviews = session.history.filter((task) => task.stage === 'critique');
  if (session.stage === 'critique') reviews.push(...session.tasks);
  const result = Object.create(null);

  for (const task of reviews) {
    const round = task.round ?? session.round;
    let prompt;
    let materials;
    if (round === 1) {
      const own = latestByProvider(independent, task.provider);
      materials = independent.filter((source) => source.provider !== task.provider);
      prompt = critiquePrompt(session.question, task.provider, own, materials, missing);
    } else {
      const proposal = latestAnsweredProposal(session.history.filter((source) => source.round < round));
      if (!proposal) continue;
      const digest = proposalDigest(proposal);
      const concerns = answeredHistory(session, 'vote').filter(
        (source) =>
          source.round === round - 1 &&
          source.version === proposal.version &&
          source.proposalDigest === digest &&
          (source.stance === 'oppose' || (source.stance === 'conditional' && session.followConditions === true)),
      );
      materials = [proposal, ...concerns];
      prompt = targetedCritiquePrompt(session.question, task.provider, proposal, concerns);
    }
    const notes = (session.guidance ?? []).filter((note) => task.guidanceSeqs?.includes(note.seq));
    if (notes.length > 0) prompt = appendGuidance(prompt, notes);
    if (task.prompt === prompt) {
      result[task.id] = materials.map(({ provider, sourceId, stage }) => ({ provider, sourceId, stage }));
    }
  }
  return result;
}

function sourceBlock(task) {
  // R03/R05: frozen peer and candidate text is embedded in full. Truncating
  // the middle silently drops the one objection that may decide the issue.
  return [
    `[${task.sourceId ?? 'S?'} · ${task.provider} · ${task.stage} · 第${task.round}轮]`,
    String(task.answer ?? ''),
  ].join('\n');
}

function validateProposalReferences(session, text) {
  const refs = extractSourceRefs(text);
  const known = answeredSourceIds(session);
  const invalid = refs.filter((ref) => !known.has(ref));
  if (invalid.length === 0) return;

  const valid = [...known].sort((left, right) => sourceNumber(left) - sourceNumber(right));
  throw new Error(
    `candidate cites ${invalid.map((ref) => `[${ref}]`).join(', ')}, which ${
      invalid.length === 1 ? 'is' : 'are'
    } not an answered source in this session; valid source ids: ${
      valid.join(', ') || 'none'
    }. Nothing was submitted and no vote has been issued: correct or remove the invalid reference(s), then paste the complete corrected candidate again.`,
  );
}

function answeredSourceIds(session) {
  const ids = new Set();
  for (const task of session.history) {
    if (isUsableAnswer(task) && task.sourceId) ids.add(task.sourceId);
  }
  return ids;
}

function proposalCitationState(session, proposal) {
  const known = answeredSourceIds(session);
  // A candidate citing its own record is not independent evidence.
  if (proposal?.sourceId) known.delete(proposal.sourceId);
  const refs = proposal ? extractSourceRefs(proposal.answer) : [];
  return {
    refs,
    valid: refs.filter((ref) => known.has(ref)),
    invalid: refs.filter((ref) => !known.has(ref)),
  };
}

function isUsableAnswer(task) {
  return (
    Boolean(task) &&
    task.status === 'answered' &&
    typeof task.answer === 'string' &&
    task.answer.trim().length > 0
  );
}

/** Embed a saved answer in the local report without dropping its middle. */
function reportMaterial(task) {
  return String(task.answer ?? '').trim();
}

function extractSourceRefs(text) {
  const refs = new Set();
  const brackets = String(text ?? '').matchAll(/\[([^\]]+)\]/g);
  for (const bracket of brackets) {
    const tokens = bracket[1].matchAll(/\bS(\d+)\b/g);
    for (const token of tokens) refs.add(`S${token[1]}`);
  }
  return [...refs];
}

// ---------------------------------------------------------------------------
// Markdown report
// ---------------------------------------------------------------------------

/** The reader and Markdown export use the same candidate and ballot filters. */
export function reportBallot(history) {
  const proposal = latestAnsweredProposal(history);
  const version = proposal ? proposal.version : 0;
  const digest = proposal ? proposalDigest(proposal) : null;
  const voteTasks = history.filter(
    (task) => task.stage === 'vote' && task.version === version,
  );
  const votes = voteTasks.filter(
    (task) =>
      task.status === 'answered' &&
      STANCES.includes(task.stance) &&
      (digest === null || task.proposalDigest === digest),
  );
  return { proposal, version, votes };
}

function buildReport(session, reason) {
  const history = session.history;
  const answered = history.filter(
    (task) =>
      task.status === 'answered' &&
      typeof task.answer === 'string' &&
      task.answer.trim().length > 0,
  );
  const { proposal, version, votes } = reportBallot(history);
  const skipped = history.filter((task) => task.status === 'skipped');
  // Pending entries only survive an early user finish: the stage was archived
  // before it completed. They are outstanding work, not absences and not
  // silent agreement.
  const pending = history.filter((task) => task.status === 'pending');
  const critiques = answered.filter((task) => task.stage === 'critique');
  const currentVoteIds = new Set(votes.map((task) => task.id));
  const olderVotes = history.filter(
    (task) =>
      task.stage === 'vote' &&
      task.status === 'answered' &&
      STANCES.includes(task.stance) &&
      !currentVoteIds.has(task.id),
  );

  const lines = ['# AI Arena 讨论结论', ''];
  lines.push('## 状态', '');
  lines.push(`- ${statusLabel(reason)}`);
  const maxRounds = sessionMaxRounds(session);
  const reviewRounds = critiqueRoundCount(history);
  if (reviewRounds > 0) lines.push('- ' + reviewRoundLabel(reviewRounds, maxRounds));
  lines.push(`- 候选版本：${version > 0 ? `v${version}` : '无'}`);
  lines.push(`- 参与席位：${session.providers.map((p) => `\`${p}\``).join('、')}`);
  const independentSeats = session.providers.filter((provider) =>
    history.some(
      (task) =>
        task.stage === 'independent' &&
        task.provider === provider &&
        isUsableAnswer(task),
    ),
  );
  const crossReviewSeats = session.providers.filter((provider) =>
    history.some(
      (task) =>
        task.stage === 'critique' &&
        task.round === session.round &&
        task.provider === provider &&
        isUsableAnswer(task),
    ),
  );
  lines.push(
    `- 独立回答席位：${independentSeats.map((p) => `\`${p}\``).join('、') || '无'}（${independentSeats.length}/${session.providers.length}）`,
  );
  lines.push(
    `- 本轮互评席位：${crossReviewSeats.map((p) => `\`${p}\``).join('、') || '无'}（${crossReviewSeats.length}/${session.providers.length}）`,
  );
  if (reviewRounds >= maxRounds) {
    if (reason === 'conditional-agreement') {
      lines.push(
        `- 已到轮数上限（${maxRounds} 轮）：仍有附加条件未解决，这些条件保留在下方原文中，未计为无条件同意。`,
      );
    } else if (reason === 'unresolved-opposition') {
      lines.push(
        `- 已到轮数上限（${maxRounds} 轮）：仍有明确反对未解决，分歧保留在下方原文中。`,
      );
    }
  }
  if (reason === 'user-finished') {
    const last = history.length > 0 ? history[history.length - 1] : null;
    lines.push(
      last
        ? `- 提前结束阶段：${reportStage(last, maxRounds)}，该阶段未完成`
        : '- 提前结束阶段：无',
    );
    if (pending.length > 0) {
      lines.push(
        `- 未完成席位：${pendingSeatLabels(pending, maxRounds)}；状态仍为 pending（尚未提交），未计为同意，也不代表其他席位缺席。`,
      );
    }
  }
  lines.push('');

  lines.push('## 原始问题', '');
  for (const line of String(session.question).split('\n')) {
    lines.push(`> ${line}`);
  }
  lines.push('');

  if (session.attachments?.length) {
    lines.push('## 开场附件', '');
    let imageNumber = 0;
    for (const file of session.attachments) {
      const method = file.kind === 'image' ? `图 ${++imageNumber} · 原图` : '文本 · 随题面发送';
      // A Finder filename can itself contain Markdown.
      const name = file.name.replace(/[\\`*_{}\[\]()<>!|~]/g, '\\$&');
      lines.push(`- ${name}（${method}，${file.byteCount} 字节）`);
    }
    lines.push('', '首轮材料核对', '');
    for (const provider of session.providers) {
      const task = history.find((item) => item.stage === 'independent' && item.provider === provider);
      let status = '待核对';
      if (task?.attachmentReceipt === 'verified') status = '已在原页核对';
      else if (task?.attachmentReceipt === 'manual') status = '已由用户核对';
      if (task?.status === 'skipped') status += '（本席已跳过）';
      lines.push(`- ${provider}：${status}`);
    }
    lines.push('');
  }

  const guidance = orderedGuidance(session);
  if (guidance.length > 0) {
    lines.push('## 用户补充条件', '');
    lines.push(
      '以下为用户在讨论暂停时追加的条件，按提出顺序保存，原文照录。它们是用户输入，未经事实核验，也不代表模型或证据已经确认。',
      '',
    );
    for (const note of guidance) {
      lines.push(
        `- 补充 #${note.seq} · ${formatGuidanceTime(note.createdAt)} · ${reportStage(note, maxRounds)}提出：${note.text}`,
      );
      lines.push(`  - 随新任务发出：${guidanceDelivery(session, note, maxRounds)}`);
    }
    lines.push('');
  }

  if (proposal) {
    lines.push(
      '## 建议回答',
      '',
      `候选版本 v${version}（来源 [${proposal.sourceId}]，起草席位 \`${proposal.provider}\`）`,
      '',
      String(proposal.answer).trim(),
      '',
    );
  } else {
    lines.push(
      '## 建议回答',
      '',
      '尚无可用的候选结论。以下保留已收到的材料，供人工判断。',
      '',
    );
  }

  // R05: an objection that appeared only in the first round must survive into
  // the report verbatim; a summary excerpt could drop it.
  const independentAnswers = answered.filter(
    (task) => task.stage === 'independent',
  );
  lines.push('## 独立回答', '');
  if (independentAnswers.length === 0) {
    lines.push('- 没有可用的独立回答。');
  } else {
    for (const task of independentAnswers) {
      lines.push(
        `### [${task.sourceId}] \`${task.provider}\``,
        '',
        reportMaterial(task),
        '',
      );
    }
  }
  lines.push('');

  lines.push('## 各席最终表态', '');
  if (!proposal) {
    lines.push('- 尚未进入对候选结论的表态。');
  } else if (votes.length === 0) {
    lines.push('- 当前候选版本没有有效表态；未表态不能视为同意。');
  } else {
    for (const provider of session.providers) {
      const vote = votes.find((task) => task.provider === provider);
      if (!vote) {
        lines.push(
          `- \`${provider}\`：未对 v${version} 明确表态（不能视为同意）`,
        );
        continue;
      }
      lines.push(
        `- \`${provider}\`：${STANCE_LABELS[vote.stance]} — ${reportMaterial(
          vote,
        )} [${vote.sourceId}]`,
      );
    }
  }
  lines.push('');

  const opposeVotes = votes.filter((task) => task.stance === 'oppose');
  const conditionalVotes = votes.filter(
    (task) => task.stance === 'conditional',
  );
  lines.push('## 未解决分歧与附加条件', '');
  if (opposeVotes.length === 0 && conditionalVotes.length === 0) {
    lines.push('- 当前版本没有记录到明确反对或附加条件。');
  }
  for (const vote of opposeVotes) {
    lines.push(
      `- 明确反对：\`${vote.provider}\` — ${reportMaterial(vote)} [${vote.sourceId}]`,
    );
  }
  for (const vote of conditionalVotes) {
    lines.push(
      `- 附加条件：\`${vote.provider}\` — ${reportMaterial(vote)} [${vote.sourceId}]`,
    );
  }
  lines.push('');

  lines.push('## 互评与最强反例', '');
  if (critiques.length === 0) {
    lines.push('- 没有可用的互评材料。');
  } else {
    for (const task of critiques) {
      lines.push(
        `### [${task.sourceId}] \`${task.provider}\` · ${reviewRoundLabel(task.round, maxRounds)}`,
        '',
        reportMaterial(task),
        '',
      );
    }
  }

  if (olderVotes.length > 0) {
    lines.push('## 往轮表态（不计入当前版本）', '');
    for (const vote of olderVotes) {
      lines.push(
        `- v${vote.version} · \`${vote.provider}\`：${STANCE_LABELS[vote.stance]} — ${reportMaterial(vote)} [${vote.sourceId}]`,
      );
    }
    lines.push('');
  }

  lines.push('## 缺席与跳过', '');
  if (skipped.length === 0 && pending.length === 0) {
    lines.push('- 无。');
  } else {
    for (const task of skipped) {
      lines.push(
        `- \`${task.provider}\` 在「${reportStage(task, maxRounds)}」跳过。`,
      );
    }
    for (const task of pending) {
      lines.push(
        `- \`${task.provider}\` 在「${reportStage(task, maxRounds)}」尚未提交，状态仍为 pending；不计为同意。`,
      );
    }
  }
  lines.push('');

  lines.push('## 证据出处', '');
  lines.push('以下为摘要索引；完整原文见上文各阶段小节，[S#] 与本场历史一一对应。');
  lines.push('');
  const sorted = answered
    .filter((task) => task.sourceId)
    .slice()
    .sort(
      (left, right) =>
        sourceNumber(left.sourceId) - sourceNumber(right.sourceId),
    );
  if (sorted.length === 0) {
    lines.push('- 没有已完成的回答。');
  } else {
    for (const task of sorted) {
      lines.push(
        `- [${task.sourceId}] \`${task.provider}\` · ${reportStage(task, maxRounds)} — ${excerpt(task.answer, 220)}`,
      );
    }
  }
  lines.push('');

  const evidenceIds = new Set(sorted.map((task) => task.sourceId));
  const citation = proposalCitationState(session, proposal);
  const proposalRefs = citation.refs;
  const validProposalRefs = citation.valid;
  const missingProposalRefs = citation.invalid;
  const brokenRefs = new Set();
  for (const task of answered) {
    for (const ref of extractSourceRefs(task.answer)) {
      if (!evidenceIds.has(ref)) brokenRefs.add(ref);
    }
  }

  lines.push('## 引用校验', '');
  if (!proposal) {
    lines.push('- 尚无候选结论可供校验。');
  } else if (proposalRefs.length === 0) {
    lines.push(
      '- 候选结论没有标注任何 [S#] 来源编号。本场只能按草稿处理：即使每席都点了同意，也不构成可核验的全体一致；关键判断需要人工回溯原文。',
    );
  } else if (validProposalRefs.length === 0) {
    lines.push(
      `- 候选结论的引用全部无法核实：${missingProposalRefs.map((ref) => `[${ref}]`).join('、')}。本场只能按草稿处理，不构成全体一致。`,
    );
  } else {
    lines.push(
      `- 候选结论的有效来源：${validProposalRefs.map((ref) => `[${ref}]`).join('、')}`,
    );
    if (missingProposalRefs.length > 0) {
      lines.push(
        `- 候选结论中无法核实的引用：${missingProposalRefs.map((ref) => `[${ref}]`).join('、')}（不作为证据；应退回草稿或人工核对）`,
      );
    }
  }
  if (brokenRefs.size > 0) {
    lines.push(
      `- 其他回答中指向缺失来源的引用：${[...brokenRefs].map((ref) => `[${ref}]`).join('、')}（未计入证据）`,
    );
  }
  lines.push('');

  lines.push(
    '## 说明',
    '',
    '本报告由本地模板根据已保存的发言生成；[S#] 指向本场历史记录。模型陈述未经事实核验；缺席、跳过、超时与沉默均未被计为同意。',
    '',
  );

  return lines.join('\n');
}

function orderedGuidance(session) {
  const notes = Array.isArray(session.guidance) ? session.guidance : [];
  return notes
    .slice()
    .sort(
      (left, right) =>
        (Number(left.seq) || 0) - (Number(right.seq) || 0) ||
        (Number(left.createdAt) || 0) -
        (Number(right.createdAt) || 0),
    );
}

/** Name the exact newly issued tasks that carried this condition. */
function guidanceDelivery(session, note, maxRounds) {
  const ids = Array.isArray(note.deliveredTo) ? note.deliveredTo : [];
  const labels = [];
  for (const id of ids) {
    const task =
      session.tasks.find((candidate) => candidate.id === id) ||
      session.history.find((candidate) => candidate.id === id);
    if (!task) continue;
    const label = `（${reportStage(task, maxRounds)}）· ${task.provider}`;
    if (!labels.includes(label)) labels.push(label);
  }
  return labels.length > 0 ? labels.join('；') : '尚未随新任务发出';
}

function formatGuidanceTime(at) {
  const date = new Date(Number(at) || 0);
  if (Number.isNaN(date.getTime())) return '时间未知';
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(
    date.getDate(),
  )} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function pendingSeatLabels(pending, maxRounds) {
  return pending
    .map(
      (task) =>
        `\`${task.provider}\`（${reportStage(task, maxRounds)}）`,
    )
    .join('、');
}

function statusLabel(reason) {
  switch (reason) {
    case 'consensus':
      return '全体一致：每位参与者都独立作答、完成本轮互评，并对同一候选版本的完整文本明确同意，没有未解决反对或附加条件。';
    case 'conditional-agreement':
      return '有条件一致：没有明确反对，但至少一席附加了条件；这不等于全体无条件同意。';
    case 'unresolved-opposition':
      return '未解决分歧：当前版本仍有明确反对，未形成共识。';
    case 'partial-votes':
      return '部分完成：有席位未对当前候选版本明确表态；沉默、缺席或跳过均不计为同意。';
    case 'partial-participation':
      return '部分完成：有席位没有提供独立回答，参与席位不齐；即使其余席位点了同意，也不构成全体一致。';
    case 'no-cross-review':
      return '部分完成：至少一席没有提交本轮的互评回应；仅收到对方文字不等于完成互评，不能声称全体一致。';
    case 'draft':
      return '草稿：候选结论缺少可核实的 [S#] 出处，未形成可核验的全体一致；请按草稿使用或重新起草。';
    case 'proposal-skipped':
      return '部分完成：候选结论没有完成，未进入有效表态。';
    case 'no-critique':
      return '部分完成：独立回答已收到，但缺少可用的互评材料。';
    case 'no-answers':
      return '未形成结论：没有收到有效回答。';
    case 'no-tasks':
      return '已结束：没有可继续执行的任务。';
    case 'user-finished':
      return '用户提前结束：保留当前部分结果，未声称达成共识。';
    default:
      return `已结束（${reason}）。`;
  }
}

function reviewRoundLabel(round, maxRounds) {
  return `互评第 ${round} 轮 / 上限 ${maxRounds}`;
}

function reportStage(task, maxRounds) {
  const stage = STAGE_LABELS[task.stage] ?? task.stage;
  if (task.stage === 'independent') return stage;
  // The round label already starts with 互评, so a critique task names it once.
  const round = reviewRoundLabel(task.round, maxRounds);
  return task.stage === 'critique' ? round : stage + ' · ' + round;
}

/** Review cycles that began, whether their tasks were answered, skipped or left pending. */
function critiqueRoundCount(history) {
  const rounds = new Set(
    history
      .filter((task) => task.stage === 'critique')
      .map((task) => task.round),
  );
  return rounds.size;
}

function sourceNumber(sourceId) {
  const match = /^S(\d+)$/.exec(String(sourceId));
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function assertSession(session) {
  if (
    !session ||
    typeof session !== 'object' ||
    !Array.isArray(session.providers) ||
    !Array.isArray(session.tasks) ||
    !Array.isArray(session.history) ||
    typeof session.question !== 'string' ||
    typeof session.stage !== 'string'
  ) {
    throw new Error('invalid session');
  }
}

function clone(value) {
  if (typeof structuredClone === 'function') return structuredClone(value);
  return JSON.parse(JSON.stringify(value));
}

function touch(next, previous) {
  next.updatedAt = Math.max(Date.now(), (previous.updatedAt ?? 0) + 1);
}

function makeSessionId() {
  const cryptoApi = globalThis.crypto;
  if (cryptoApi && typeof cryptoApi.randomUUID === 'function') {
    return `arena-${cryptoApi.randomUUID()}`;
  }
  return `arena-${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2, 10)}`;
}

function excerpt(text, limit) {
  const value = String(text ?? '')
    .replace(/\s+/g, ' ')
    .trim();
  if (value.length <= limit) return value;
  return `${value.slice(0, limit)}…`;
}
