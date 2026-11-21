import test from 'node:test';
import assert from 'node:assert/strict';

import { createSession, applyAction } from '../extension/core.js';

const QUESTION = '我的笔记工具值不值得先做移动端？我只有两个周末。';
const PROVIDERS = ['chatgpt', 'claude'];

function start() {
  return createSession(QUESTION, PROVIDERS);
}

function pendingTask(session, provider) {
  const task = session.tasks.find(
    (candidate) =>
      candidate.provider === provider && candidate.status === 'pending',
  );
  assert.ok(
    task,
    `expected a pending task for ${provider} in stage ${session.stage}`,
  );
  return task;
}

function answerFor(session, provider, text, extra = {}) {
  const task = pendingTask(session, provider);
  return applyAction(session, 'answer', {
    taskId: task.id,
    text,
    ...extra,
  });
}

function skipFor(session, provider) {
  const task = pendingTask(session, provider);
  return applyAction(session, 'skip', { taskId: task.id });
}

/** Drive a fresh session to the first vote stage with distinct answers. */
function toVote(
  candidate = 'CANDIDATE_V1 先用手机快捷入口验证采集频次，再决定是否做完整移动端。[S1][S3]',
) {
  let session = start();
  session = answerFor(
    session,
    'chatgpt',
    'CHATGPT_INDEPENDENT 先做移动端，因为采集常发生在路上。',
  );
  session = answerFor(
    session,
    'claude',
    'CLAUDE_INDEPENDENT 先补桌面检索，现有证据只证明检索慢。',
  );
  assert.equal(session.stage, 'critique');

  session = answerFor(
    session,
    'chatgpt',
    'CHATGPT_CRITIQUE 回应 CLAUDE_INDEPENDENT：采集频次尚未被证实。',
  );
  session = answerFor(
    session,
    'claude',
    'CLAUDE_CRITIQUE 回应 CHATGPT_INDEPENDENT：检索慢是已知事实。',
  );
  assert.equal(session.stage, 'proposal');

  session = answerFor(session, 'chatgpt', candidate);
  assert.equal(session.stage, 'vote');
  return session;
}

function voteAll(session, stances, texts) {
  let next = session;
  for (const provider of PROVIDERS) {
    next = answerFor(next, provider, texts[provider], {
      stance: stances[provider],
    });
  }
  return next;
}

// ---------------------------------------------------------------------------
// createSession
// ---------------------------------------------------------------------------

test('createSession validates question, provider count, duplicates and canonical ids', () => {
  assert.throws(() => createSession('', PROVIDERS), /non-empty/);
  assert.throws(() => createSession('   ', PROVIDERS), /non-empty/);
  assert.throws(() => createSession(123, PROVIDERS), /non-empty/);
  assert.throws(() => createSession(QUESTION, ['chatgpt']), /two distinct/);
  assert.throws(
    () => createSession(QUESTION, ['chatgpt', 'claude', 'gemini']),
    /two distinct/,
  );
  assert.throws(
    () => createSession(QUESTION, ['chatgpt', 'chatgpt']),
    /distinct/,
  );
  assert.throws(
    () => createSession(QUESTION, ['ChatGPT', 'claude']),
    /canonical lowercase/,
  );
  assert.throws(
    () => createSession(QUESTION, ['chat gpt', 'claude']),
    /canonical lowercase/,
  );
  assert.throws(() => createSession(QUESTION, 'chatgpt,claude'), /two distinct/);

  // Hyphens and digits are part of the canonical id vocabulary.
  const session = createSession(QUESTION, ['chat-gpt4', 'claude']);
  assert.deepEqual(session.providers, ['chat-gpt4', 'claude']);
});

test('createSession starts with only pending independent tasks and no demo answers', () => {
  const session = start();

  assert.equal(session.stage, 'independent');
  assert.equal(session.round, 1);
  assert.equal(session.paused, false);
  assert.equal(session.history.length, 0);
  assert.equal(session.report, undefined);
  assert.equal(session.tasks.length, 2);
  assert.equal(typeof session.updatedAt, 'number');
  assert.deepEqual(session.providers, PROVIDERS);

  for (const task of session.tasks) {
    assert.equal(task.status, 'pending');
    assert.equal('answer' in task, false);
    assert.ok(task.id);
    assert.match(task.prompt, new RegExp(QUESTION.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.notEqual(session.tasks[0].id, session.tasks[1].id);
});

test('independent prompts are private and byte-identical for both seats', () => {
  const session = start();
  assert.equal(session.tasks[0].prompt, session.tasks[1].prompt);
  for (const task of session.tasks) {
    assert.doesNotMatch(task.prompt, /【对方材料】/);
    assert.doesNotMatch(task.prompt, /CLAUDE_INDEPENDENT/);
    assert.doesNotMatch(task.prompt, /CHATGPT_INDEPENDENT/);
    // R02: seat identity belongs to the task record, not to the shared prompt.
    assert.doesNotMatch(task.prompt, /chatgpt|claude/);
  }
});

// ---------------------------------------------------------------------------
// Independent -> critique
// ---------------------------------------------------------------------------

test('independent answers auto-advance to critique with opponent material and source ids', () => {
  let session = start();
  const firstId = session.tasks[0].id;
  session = applyAction(session, 'answer', {
    taskId: firstId,
    text: 'CHATGPT_INDEPENDENT 先做移动端。',
  });

  assert.equal(session.stage, 'independent');
  assert.equal(session.tasks.length, 2);
  assert.equal(session.history.length, 0);

  session = answerFor(session, 'claude', 'CLAUDE_INDEPENDENT 先补桌面检索。');

  assert.equal(session.stage, 'critique');
  assert.equal(session.tasks.length, 2);
  assert.equal(session.history.length, 2);
  for (const task of session.tasks) assert.equal(task.status, 'pending');
  for (const entry of session.history) {
    assert.equal(entry.stage, 'independent');
    assert.equal(entry.round, 1);
    assert.equal(entry.status, 'answered');
  }

  const chatgptCritique = session.tasks.find(
    (task) => task.provider === 'chatgpt',
  );
  assert.match(chatgptCritique.prompt, /CLAUDE_INDEPENDENT/);
  assert.match(chatgptCritique.prompt, /CHATGPT_INDEPENDENT/);
  assert.match(chatgptCritique.prompt, /\[S1/);
  assert.match(chatgptCritique.prompt, /\[S2/);
  assert.match(chatgptCritique.prompt, /反例/);
  assert.match(chatgptCritique.prompt, new RegExp(QUESTION));
});

test('skipping one independent seat keeps the skipped state and excludes it from opponents', () => {
  let session = start();
  const skippedId = pendingTask(session, 'chatgpt').id;
  session = applyAction(session, 'skip', { taskId: skippedId });
  session = answerFor(session, 'claude', 'CLAUDE_ONLY 只有一席回答。');

  assert.equal(session.stage, 'critique');
  assert.equal(session.history.length, 2);
  const skipped = session.history.find((entry) => entry.id === skippedId);
  assert.equal(skipped.status, 'skipped');
  assert.equal('answer' in skipped, false);

  // Only the seat with a usable independent answer gets a critique task.
  assert.equal(session.tasks.length, 1);
  assert.equal(session.tasks[0].provider, 'claude');
  assert.match(session.tasks[0].prompt, /缺席席位】chatgpt/);
  assert.doesNotMatch(session.tasks[0].prompt, /CHATGPT_ONLY/);
});

test('a fully attended two-seat critique never marks the recipient itself absent', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'CHATGPT_PRESENT 先做移动端。');
  session = answerFor(session, 'claude', 'CLAUDE_PRESENT 先补桌面检索。');
  assert.equal(session.stage, 'critique');
  assert.equal(session.tasks.length, 2);

  for (const task of session.tasks) {
    const other = task.provider === 'chatgpt' ? 'claude' : 'chatgpt';
    const otherEntry = session.history.find(
      (entry) => entry.stage === 'independent' && entry.provider === other,
    );
    assert.ok(otherEntry);

    // Regression: the recipient used to appear in 【缺席席位】 because it was
    // excluded from its own opponent list. With both seats present nothing is
    // absent, and the peer answer still arrives in full.
    assert.doesNotMatch(task.prompt, /【缺席席位】/);
    assert.ok(task.prompt.includes(otherEntry.answer));
    assert.match(task.prompt, new RegExp(`\\[${otherEntry.sourceId} · ${other}`));
  }
});

// ---------------------------------------------------------------------------
// Validation and stale / overdue submissions
// ---------------------------------------------------------------------------

test('unknown, duplicate, skipped and stale task ids are rejected', () => {
  let session = start();
  const first = pendingTask(session, 'chatgpt');

  assert.throws(
    () => applyAction(session, 'answer', { taskId: 'missing', text: 'x' }),
    /unknown task/,
  );
  assert.throws(
    () => applyAction(session, 'answer', { taskId: first.id, text: '   ' }),
    /non-empty/,
  );
  assert.throws(
    () => applyAction(session, 'answer', { taskId: first.id }),
    /non-empty/,
  );

  session = applyAction(session, 'answer', {
    taskId: first.id,
    text: 'answered once',
  });
  assert.throws(
    () =>
      applyAction(session, 'answer', {
        taskId: first.id,
        text: 'answered twice',
      }),
    /already answered/,
  );

  let skippedSession = start();
  const skippedTask = pendingTask(skippedSession, 'chatgpt');
  skippedSession = applyAction(skippedSession, 'skip', {
    taskId: skippedTask.id,
  });
  assert.throws(
    () =>
      applyAction(skippedSession, 'answer', {
        taskId: skippedTask.id,
        text: 'late reply',
      }),
    /was skipped/,
  );

  // After the stage advances, the old independent task is stale.
  let advanced = start();
  const oldId = pendingTask(advanced, 'chatgpt').id;
  advanced = answerFor(advanced, 'chatgpt', 'A');
  advanced = answerFor(advanced, 'claude', 'B');
  assert.equal(advanced.stage, 'critique');
  assert.throws(
    () =>
      applyAction(advanced, 'answer', {
        taskId: oldId,
        text: 'overdue answer',
      }),
    /stale submission/,
  );

  // Explicit stage/round coordinates reject an overdue delivery.
  const critiqueTask = advanced.tasks[0];
  assert.throws(
    () =>
      applyAction(advanced, 'answer', {
        taskId: critiqueTask.id,
        text: 'wrong round',
        round: 2,
      }),
    /stale submission/,
  );
  assert.throws(
    () =>
      applyAction(advanced, 'answer', {
        taskId: critiqueTask.id,
        text: 'wrong stage',
        stage: 'proposal',
      }),
    /stale submission/,
  );
});

test('applyAction never mutates the input session', () => {
  const session = start();
  const before = JSON.stringify(session);
  applyAction(session, 'answer', {
    taskId: pendingTask(session, 'chatgpt').id,
    text: 'immutable',
  });
  assert.equal(JSON.stringify(session), before);
});

test('task ids stay stable and history entries are immutable', () => {
  let session = start();
  const claudeId = pendingTask(session, 'claude').id;
  session = answerFor(session, 'chatgpt', 'A');
  assert.equal(pendingTask(session, 'claude').id, claudeId);

  session = answerFor(session, 'claude', 'B');
  const independentHistory = JSON.stringify(session.history);

  session = answerFor(session, 'chatgpt', 'C');
  session = answerFor(session, 'claude', 'D');
  const proposalHistory = JSON.stringify(session.history.slice(0, 2));
  assert.equal(proposalHistory, independentHistory);

  session = answerFor(session, 'chatgpt', 'E');
  assert.equal(JSON.stringify(session.history.slice(0, 2)), independentHistory);
});

// ---------------------------------------------------------------------------
// Pause / resume / finish
// ---------------------------------------------------------------------------

test('pause defers auto-advance and resume completes the stage', () => {
  let session = start();
  session = applyAction(session, 'pause');
  assert.equal(session.paused, true);

  session = answerFor(session, 'chatgpt', 'A');
  session = answerFor(session, 'claude', 'B');

  assert.equal(session.stage, 'independent');
  assert.equal(session.paused, true);
  assert.ok(session.tasks.every((task) => task.status === 'answered'));

  session = applyAction(session, 'resume');
  assert.equal(session.paused, false);
  assert.equal(session.stage, 'critique');
  assert.equal(session.history.length, 2);
});

test('finish early produces a partial report and is idempotent', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'CHATGPT_EARLY 已有回答。');
  const pendingClaude = pendingTask(session, 'claude');

  session = applyAction(session, 'finish');
  assert.equal(session.stage, 'done');
  assert.equal(session.tasks.length, 0);
  assert.equal(session.stopReason, 'user-finished');
  assert.equal(session.history.length, 2);
  assert.equal(
    session.history.find((entry) => entry.id === pendingClaude.id).status,
    'pending',
  );
  assert.match(session.report, /用户提前结束/);
  assert.match(session.report, /CHATGPT_EARLY/);
  assert.doesNotMatch(session.report, /全体一致/);

  const again = applyAction(session, 'finish');
  assert.equal(again.updatedAt, session.updatedAt);
  assert.equal(again.report, session.report);

  assert.throws(
    () =>
      applyAction(session, 'answer', {
        taskId: 'anything',
        text: 'after finish',
      }),
    /done/,
  );
});

test('an early finish names the outstanding seat and stage, never implying nobody is missing', () => {
  let session = toVote();
  session = answerFor(session, 'chatgpt', 'EARLY_VOTE_AGREE 同意。', {
    stance: 'agree',
  });
  const pendingClaude = pendingTask(session, 'claude');

  session = applyAction(session, 'finish');
  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'user-finished');
  assert.equal(
    session.history.find((entry) => entry.id === pendingClaude.id).status,
    'pending',
  );

  // The unfinished stage and the seats still pending are named explicitly...
  assert.match(session.report, /提前结束阶段：表决（第1轮），该阶段未完成/);
  assert.match(session.report, /未完成席位：`claude`（表决 · 第1轮）/);
  assert.match(
    session.report,
    /`claude` 在表决（第1轮）尚未提交，状态仍为 pending；不计为同意/,
  );
  // ...and the absence section never collapses to "无" while a seat is pending.
  assert.doesNotMatch(session.report, /## 缺席与跳过\n\n- 无。/);
  assert.doesNotMatch(session.report, /全体一致/);
});

// ---------------------------------------------------------------------------
// Vote stage
// ---------------------------------------------------------------------------

test('vote requires a stance and rejects stale candidate versions', () => {
  const session = toVote();
  const firstVote = session.tasks[0];

  assert.throws(
    () =>
      applyAction(session, 'answer', {
        taskId: firstVote.id,
        text: 'no stance',
      }),
    /stance/,
  );
  assert.throws(
    () =>
      applyAction(session, 'answer', {
        taskId: firstVote.id,
        text: 'bad stance',
        stance: 'maybe',
      }),
    /stance/,
  );
  assert.throws(
    () =>
      applyAction(session, 'answer', {
        taskId: firstVote.id,
        text: 'old version',
        stance: 'agree',
        version: 99,
      }),
    /stale submission/,
  );

  const next = applyAction(session, 'answer', {
    taskId: firstVote.id,
    text: 'valid',
    stance: 'agree',
    version: firstVote.version,
  });
  assert.equal(next.stage, 'vote');
  assert.equal(
    next.tasks.find((task) => task.id === firstVote.id).status,
    'answered',
  );
  assert.equal(
    next.tasks.filter((task) => task.status === 'pending').length,
    1,
  );
});

test('unanimous explicit agreement produces a final report with source ids', () => {
  let session = toVote();
  const version = session.tasks[0].version;

  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'agree' },
    {
      chatgpt: 'VOTE_CHATGPT 同意，因为采集频次假设值得先验证。',
      claude: 'VOTE_CLAUDE 同意，条件和证据边界写清楚了。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.tasks.length, 0);
  assert.equal(session.stopReason, 'consensus');
  assert.equal(session.paused, false);
  assert.equal(typeof session.report, 'string');

  assert.match(session.report, /全体一致/);
  assert.match(session.report, /CANDIDATE_V1/);
  assert.match(session.report, /VOTE_CHATGPT/);
  assert.match(session.report, /VOTE_CLAUDE/);
  assert.match(session.report, new RegExp(`v${version}`));
  assert.match(session.report, /\[S1\]/);
  assert.match(session.report, /\[S2\]/);
  assert.match(session.report, new RegExp(QUESTION));
  assert.match(session.report, /证据出处/);
  assert.match(session.report, /引用校验/);
  assert.match(session.report, /有效来源：\[S1\]、\[S3\]/);

  // Every answered source is listed and every listed source id is unique.
  const sourceIds = session.history
    .filter((entry) => entry.status === 'answered')
    .map((entry) => entry.sourceId);
  assert.equal(new Set(sourceIds).size, sourceIds.length);
  for (const sourceId of sourceIds) {
    assert.match(session.report, new RegExp(`\\[${sourceId}\\]`));
  }
});

test('unknown or out-of-session candidate references are rejected before vote and can be corrected', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'INDEPENDENT_A [S1]');
  session = answerFor(session, 'claude', 'INDEPENDENT_B [S2]');
  session = answerFor(session, 'chatgpt', 'CRITIQUE_A [S2]');
  session = answerFor(session, 'claude', 'CRITIQUE_B [S1]');
  assert.equal(session.stage, 'proposal');

  const task = session.tasks[0];
  for (const badText of [
    'BAD_CANDIDATE [S99]',
    'OUT_OF_SESSION [S123]',
    `BAD_SELF_REFERENCE [${task.sourceId}]`,
  ]) {
    assert.throws(
      () => applyAction(session, 'answer', { taskId: task.id, text: badText }),
      (error) => {
        assert.match(error.message, /not an answered source in this session/);
        assert.match(error.message, /valid source ids: S1, S2, S3, S4/);
        assert.match(error.message, /no vote has been issued/);
        assert.match(error.message, /paste the complete corrected candidate again/);
        return true;
      },
    );
  }

  // A rejected candidate never becomes the vote target; the same task can be
  // re-pasted with corrected references.
  assert.equal(session.tasks[0].status, 'pending');
  assert.equal(
    session.history.some(
      (entry) => entry.stage === 'proposal' && entry.status === 'answered',
    ),
    false,
  );

  const next = applyAction(session, 'answer', {
    taskId: task.id,
    text: 'GOOD_CANDIDATE [S1][S2]',
  });
  assert.equal(next.stage, 'vote');
  const proposal = next.history.find((entry) => entry.stage === 'proposal');
  assert.equal(proposal.answer, 'GOOD_CANDIDATE [S1][S2]');
});

test('conditional agreement is not reported as consensus', () => {
  let session = toVote();
  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'conditional' },
    {
      chatgpt: 'VOTE_AGREE 同意。',
      claude: 'VOTE_CONDITION 只有先验证采集频次才同意。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'conditional-agreement');
  assert.match(session.report, /有条件一致/);
  assert.match(session.report, /VOTE_CONDITION/);
  assert.match(session.report, /附加条件/);
  assert.doesNotMatch(session.report, /全体一致/);
});

test('a skipped vote produces a partial report, never a false consensus', () => {
  let session = toVote();
  session = answerFor(session, 'chatgpt', 'ONLY_VOTE 同意。', {
    stance: 'agree',
  });
  session = skipFor(session, 'claude');

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'partial-votes');
  assert.match(session.report, /部分完成/);
  assert.match(session.report, /未对 v1 明确表态/);
  assert.match(session.report, /缺席与跳过/);
  assert.match(session.report, /claude.*跳过/);
  assert.doesNotMatch(session.report, /全体一致/);
});

test('a candidate without verifiable references ends as a marked draft, never consensus', () => {
  let session = toVote('CANDIDATE_DRAFT_NO_REFS 先做两周验证，但没有写出来源编号。');
  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'agree' },
    {
      chatgpt: 'DRAFT_VOTE_AGREE_A 我同意这份草稿。',
      claude: 'DRAFT_VOTE_AGREE_B 我也同意这份草稿。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'draft');
  assert.match(session.report, /草稿：候选结论缺少可核实的 \[S#\] 出处/);
  assert.match(session.report, /没有标注任何 \[S#\] 来源编号/);
  assert.match(session.report, /即使每席都点了同意/);
  assert.doesNotMatch(session.report, /^- 全体一致/m);
});

test('a seat without an independent answer cannot produce full consensus', () => {
  let session = start();
  session = skipFor(session, 'chatgpt');
  session = answerFor(
    session,
    'claude',
    'CLAUDE_ONLY_INDEPENDENT 只有一席独立作答。',
  );
  assert.equal(session.stage, 'critique');

  session = answerFor(session, 'claude', 'CLAUDE_ONLY_CRITIQUE 自反驳并保留反例。');
  assert.equal(session.stage, 'proposal');

  session = answerFor(
    session,
    'claude',
    'CANDIDATE_ONE_SEAT 只剩一席参与时的候选。[S2][S3]',
  );
  assert.equal(session.stage, 'vote');

  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'agree' },
    {
      chatgpt: 'ABSENT_SEAT_AGREE 缺席席位也点了同意。',
      claude: 'PRESENT_SEAT_AGREE 我同意。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'partial-participation');
  assert.match(session.report, /没有提供独立回答/);
  assert.match(session.report, /独立回答席位：`claude`（1\/2）/);
  assert.doesNotMatch(session.report, /^- 全体一致/m);
});

test('a seat that skipped cross-review cannot produce full consensus', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'CHATGPT_INDEPENDENT 先做移动端。');
  session = answerFor(session, 'claude', 'CLAUDE_INDEPENDENT 先补检索。');
  session = skipFor(session, 'chatgpt');
  session = answerFor(session, 'claude', 'CLAUDE_ONLY_CROSS 已完成质询。');
  assert.equal(session.stage, 'proposal');

  session = answerFor(
    session,
    'claude',
    'CANDIDATE_PARTIAL_REVIEW 未完成双边质询的候选。[S2][S4]',
  );
  assert.equal(session.stage, 'vote');

  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'agree' },
    {
      chatgpt: 'NO_REVIEW_VOTE_A 我同意。',
      claude: 'NO_REVIEW_VOTE_B 我同意。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'no-cross-review');
  assert.match(session.report, /本轮交叉质询席位：`claude`（1\/2）/);
  assert.match(session.report, /仅收到对方文字不等于完成质询/);
  assert.doesNotMatch(session.report, /^- 全体一致/m);
});

test('each vote is bound to the exact whole candidate text', () => {
  const session = toVote('CANDIDATE_EXACT_WHOLE 完整候选正文。[S1][S3]');
  const proposal = session.history.find((entry) => entry.stage === 'proposal');
  assert.ok(proposal);

  for (const voteTask of session.tasks.filter((task) => task.stage === 'vote')) {
    assert.equal(voteTask.version, proposal.version);
    assert.equal(voteTask.proposalSourceId, proposal.sourceId);
    assert.equal(typeof voteTask.proposalDigest, 'string');
    assert.match(voteTask.prompt, /唯一候选结论全文/);
    assert.match(voteTask.prompt, /CANDIDATE_EXACT_WHOLE/);
  }

  // Keeping the version number while replacing the text is stale, not a vote
  // on the full candidate.
  const tampered = JSON.parse(JSON.stringify(session));
  const tamperedProposal = tampered.history.find(
    (entry) => entry.stage === 'proposal',
  );
  tamperedProposal.answer = 'CANDIDATE_SUMMARY 被换成了摘要。[S1]';
  assert.throws(
    () =>
      applyAction(tampered, 'answer', {
        taskId: tampered.tasks[0].id,
        text: '同意摘要',
        stance: 'agree',
      }),
    /whole candidate v\d+ text changed/,
  );
});

// ---------------------------------------------------------------------------
// Targeted second critique for explicit opposition
// ---------------------------------------------------------------------------

function toSecondVote() {
  let session = toVote();
  session = answerFor(session, 'chatgpt', 'ROUND1_AGREE 同意。', {
    stance: 'agree',
  });
  session = answerFor(
    session,
    'claude',
    'ROUND1_OPPOSE 抽样证据不足，不能先做移动端。',
    { stance: 'oppose' },
  );

  assert.equal(session.stage, 'critique');
  assert.equal(session.round, 2);
  assert.equal(session.tasks.length, 2);

  session = answerFor(session, 'chatgpt', 'ROUND2_CHATGPT 回应反对意见。');
  session = answerFor(session, 'claude', 'ROUND2_CLAUDE 保留反对理由。');
  assert.equal(session.stage, 'proposal');
  assert.equal(session.tasks[0].provider, 'chatgpt');

  session = answerFor(session, 'chatgpt', 'CANDIDATE_V2 修订后的候选结论。[S8][S9]');
  assert.equal(session.stage, 'vote');
  assert.equal(session.tasks[0].version, 2);
  return session;
}

test('explicit opposition runs one targeted critique round and then stops unresolved', () => {
  let session = toVote();
  session = answerFor(session, 'chatgpt', 'ROUND1_AGREE 同意。', {
    stance: 'agree',
  });
  session = answerFor(
    session,
    'claude',
    'ROUND1_OPPOSE 抽样证据不足，不能先做移动端。',
    { stance: 'oppose' },
  );

  assert.equal(session.stage, 'critique');
  assert.equal(session.round, 2);
  const chatgptTask = session.tasks.find(
    (task) => task.provider === 'chatgpt',
  );
  const claudeTask = session.tasks.find((task) => task.provider === 'claude');
  assert.match(chatgptTask.prompt, /ROUND1_OPPOSE/);
  assert.match(chatgptTask.prompt, /定向质询/);
  assert.match(claudeTask.prompt, /你上一轮明确选择了反对/);
  assert.match(chatgptTask.prompt, /\[S/);

  session = answerFor(session, 'chatgpt', 'ROUND2_CHATGPT 回应反对。');
  session = answerFor(session, 'claude', 'ROUND2_CLAUDE 仍保留反对。');
  session = answerFor(session, 'chatgpt', 'CANDIDATE_V2 修订候选。[S8][S9]');
  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'oppose' },
    {
      chatgpt: 'R2_AGREE 同意 v2。',
      claude: 'R2_OPPOSE 仍反对 v2，证据不足。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'unresolved-opposition');
  const critiqueRounds = new Set(
    session.history
      .filter((entry) => entry.stage === 'critique')
      .map((entry) => entry.round),
  );
  assert.deepEqual([...critiqueRounds].sort(), [1, 2]);
  assert.match(session.report, /未解决分歧/);
  assert.match(session.report, /R2_OPPOSE/);
  assert.match(session.report, /往轮表决/);
  assert.match(session.report, /v1.*oppose|反对/);
  assert.doesNotMatch(session.report, /全体一致/);
});

test('opposition resolved in the second round still requires every seat to agree on v2', () => {
  let session = toSecondVote();
  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'agree' },
    {
      chatgpt: 'R2_AGREE 同意 v2。',
      claude: 'R2_NOW_AGREE 新证据说服我，同意 v2。',
    },
  );

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'consensus');
  assert.match(session.report, /全体一致/);
  assert.match(session.report, /候选版本 v2/);
  assert.match(session.report, /R2_NOW_AGREE/);
  assert.match(session.report, /往轮表决/);
  assert.match(session.report, /ROUND1_OPPOSE/);
});

// ---------------------------------------------------------------------------
// Skipped seats / proposal fallback / no-answer endings
// ---------------------------------------------------------------------------

test('a skipped drafter lets the other eligible seat draft', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'A');
  session = answerFor(session, 'claude', 'B');
  session = answerFor(session, 'chatgpt', 'C');
  session = answerFor(session, 'claude', 'D');
  assert.equal(session.stage, 'proposal');

  const drafter = session.tasks[0];
  assert.equal(drafter.provider, 'chatgpt');
  session = applyAction(session, 'skip', { taskId: drafter.id });

  assert.equal(session.stage, 'proposal');
  assert.equal(session.tasks.length, 1);
  assert.equal(session.tasks[0].provider, 'claude');

  session = answerFor(session, 'claude', 'FALLBACK_CANDIDATE 由另一席起草。');
  assert.equal(session.stage, 'vote');
  assert.equal(session.report, undefined);
});

test('both drafters skipping ends in a partial report without a vote', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'A');
  session = answerFor(session, 'claude', 'B');
  session = answerFor(session, 'chatgpt', 'C');
  session = answerFor(session, 'claude', 'D');

  session = skipFor(session, 'chatgpt');
  session = skipFor(session, 'claude');

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'proposal-skipped');
  assert.equal(session.tasks.length, 0);
  assert.match(session.report, /候选结论没有完成/);
  assert.doesNotMatch(session.report, /全体一致/);
});

test('no independent answers ends without a report claiming consensus', () => {
  let session = start();
  session = skipFor(session, 'chatgpt');
  session = skipFor(session, 'claude');

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'no-answers');
  assert.equal(session.tasks.length, 0);
  assert.equal(session.history.length, 2);
  assert.ok(session.history.every((entry) => entry.status === 'skipped'));
  assert.match(session.report, /没有收到有效回答/);
  assert.doesNotMatch(session.report, /全体一致/);
});

test('all critiques skipped ends in a partial report without a proposal', () => {
  let session = start();
  session = answerFor(session, 'chatgpt', 'A');
  session = answerFor(session, 'claude', 'B');
  session = skipFor(session, 'chatgpt');
  session = skipFor(session, 'claude');

  assert.equal(session.stage, 'done');
  assert.equal(session.stopReason, 'no-critique');
  assert.match(session.report, /缺少可用的质询材料/);
  assert.match(session.report, /## 独立回答/);
  assert.doesNotMatch(session.report, /全体一致/);
});

// ---------------------------------------------------------------------------
// Long material and report traceability
// ---------------------------------------------------------------------------

test('frozen peer and candidate text is embedded in full, including the middle', () => {
  const middleObjection = 'UNIQUE_MIDDLE_OBJECTION_采集频次没有证据';
  const longAnswer = `LONG_START_${'x'.repeat(3000)}${middleObjection}${'y'.repeat(3000)}_LONG_END_MARKER`;

  let session = start();
  session = answerFor(session, 'chatgpt', longAnswer);
  session = answerFor(session, 'claude', 'CLAUDE_SHORT 简短回答。');

  const claudeCritique = session.tasks.find(
    (task) => task.provider === 'claude',
  );
  // R03: the whole peer answer reaches the other seat; the unique middle
  // objection may not be silently dropped.
  assert.ok(claudeCritique.prompt.includes(longAnswer));
  assert.match(claudeCritique.prompt, /LONG_START_/);
  assert.match(claudeCritique.prompt, new RegExp(middleObjection));
  assert.match(claudeCritique.prompt, /LONG_END_MARKER/);
  assert.doesNotMatch(claudeCritique.prompt, /中间省略/);

  const stored = session.history.find(
    (entry) => entry.provider === 'chatgpt' && entry.stage === 'independent',
  );
  assert.equal(stored.answer, longAnswer);

  session = answerFor(session, 'chatgpt', 'CRITIQUE_CHATGPT 收到。');
  session = answerFor(session, 'claude', 'CRITIQUE_CLAUDE 反例在中段。');

  // The drafter sees the entire frozen material, not a summary.
  const proposalTask = session.tasks[0];
  assert.ok(proposalTask.prompt.includes(longAnswer));
  assert.match(proposalTask.prompt, new RegExp(middleObjection));

  const candidateMiddle = 'CANDIDATE_UNIQUE_MIDDLE_异议保留';
  const candidate = `CANDIDATE_START ${'z'.repeat(5000)} ${candidateMiddle} ${'w'.repeat(5000)} CANDIDATE_END [S1][S3]`;
  session = answerFor(session, 'chatgpt', candidate);
  assert.equal(session.stage, 'vote');

  // R05: each vote is on the exact whole candidate, including its middle.
  for (const voteTask of session.tasks) {
    assert.ok(voteTask.prompt.includes(candidate));
    assert.match(voteTask.prompt, new RegExp(candidateMiddle));
    assert.doesNotMatch(voteTask.prompt, /中间省略/);
  }

  session = voteAll(
    session,
    { chatgpt: 'agree', claude: 'agree' },
    {
      chatgpt: 'VOTE_LONG_CHATGPT 同意全文。',
      claude: 'VOTE_LONG_CLAUDE 同意全文。',
    },
  );
  assert.equal(session.stopReason, 'consensus');
  assert.ok(session.report.includes(candidateMiddle));
  assert.ok(session.report.includes(middleObjection));
  assert.doesNotMatch(session.report, /中间省略/);
});
