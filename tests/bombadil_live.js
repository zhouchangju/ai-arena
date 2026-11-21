import { always } from "@antithesishq/bombadil";
import { actions, extract, registerCustomAction } from "@antithesishq/bombadil/browser";
export {
  noUncaughtExceptions,
  noUnhandledPromiseRejections,
} from "@antithesishq/bombadil/browser/defaults/properties";

const providers = ["chatgpt", "gemini", "deepseek"];
const question = "合成决策题：一个两人团队只剩两个周末。其个人笔记应用的桌面搜索常漏结果，手机采集常被抱怨麻烦，但两边都没有行为数据。应该先做什么？给出一个最小试验、明确的反转条件和容易忽视的反例。请用中文，避免虚构数据，尽量控制在 450 字内。";

const state = extract(({ document }) => ({
  question: document.querySelector("#question-input")?.value ?? null,
  selected: [...document.querySelectorAll(".provider-option[aria-pressed=true]")]
    .map((button) => button.dataset.providerId),
  ready: Boolean(document.querySelector(".start-row button:not(:disabled)")),
  report: document.querySelector(".report-status")?.textContent.trim() ?? "",
  finalSeats: [...new Set([...document.querySelectorAll(".timeline-seat")].map((seat) => seat.textContent))],
  startupError: Boolean(document.querySelector("#global-error:not([hidden])")),
  error: document.querySelector(".seat-card .task-error:not([hidden])")?.textContent.trim() ?? "",
  stage: document.querySelector(".step.is-current .step-label")?.textContent.trim() ?? "",
  pending: document.querySelectorAll(".seat-card.is-pending").length,
}));

const setQuestion = registerCustomAction("fill-arena-question", (document, window, text) => {
  const input = document.querySelector("#question-input");
  input.value = text;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
});

const selectSeat = registerCustomAction("select-provider", (document, _window, provider) => {
  document.querySelector(`.provider-option[data-provider-id="${provider}"]`).click();
});

const start = registerCustomAction("create-three-seat-session", (document) => {
  document.querySelector(".start-row button:not(:disabled)").click();
});

const exchange = registerCustomAction("exchange-live-responses", async (document, window) => {
  const stage = document.querySelector(".step.is-current .step-label").textContent.trim();
  const cards = [...document.querySelectorAll(".seat-card.is-pending")];
  const requests = cards.map((card) => ({
    id: card.dataset.taskId,
    provider: card.dataset.provider,
    stage,
    prompt: card.querySelector(".prompt-box .prompt-text").textContent,
  }));
  const path = "/__arena-live/";
  const posted = await window.fetch(path + "requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(requests),
  });
  if (!posted.ok) throw new Error("Could not save live requests");
  const response = await window.fetch(path + "replies", { cache: "no-store" });
  if (!response.ok) throw new Error("Could not read live replies");
  const replies = await response.json();
  const ready = requests.find((request) => replies.some((reply) => reply.id === request.id));
  if (!ready) {
    await new Promise((resolve) => window.setTimeout(resolve, 900));
    return;
  }

  const reply = replies.find(({ id }) => id === ready.id);
  const card = () => document.querySelector(`.seat-card[data-provider="${ready.provider}"]`);
  const button = (label) => [...card().querySelectorAll("button:not(:disabled)")]
    .find((item) => item.textContent.trim() === label);
  if (!card().querySelector(".answer-input")) button("粘贴回答").click();
  const input = card().querySelector(".answer-input");
  input.value = reply.text;
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  if (stage === "逐席确认") card().querySelector(`[data-stance="${reply.stance}"]`).click();
  const submit = button(stage === "逐席确认" ? "记录表态" : "提交回答");
  submit.click();
  // Wait for the actual UI submit, not the presence of a reply file.
  const until = Date.now() + 3000;
  while (submit.isConnected && submit.disabled && Date.now() < until) {
    await new Promise((resolve) => window.setTimeout(resolve, 20));
  }
});

const idle = registerCustomAction("wait-for-arena", (_document, window) =>
  new Promise((resolve) => window.setTimeout(resolve, 300)));

const finish = registerCustomAction("record-final-arena-state", async (document, window) => {
  if (document.body.dataset.liveOutcomeSent) return;
  const payload = {
    id: new URLSearchParams(window.location.hash.slice(1)).get("s"),
    report: document.querySelector(".report-status").textContent.trim(),
  };
  const result = await window.fetch("/__arena-live/outcome", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!result.ok) throw new Error("Could not preserve final state");
  document.body.dataset.liveOutcomeSent = "yes";
});

export const liveDiscussion = actions(() => {
  const view = state.current;
  if (view.report) return [finish(), idle()];
  if (view.question !== null) {
    if (view.question !== question) return [setQuestion(question)];
    const next = providers.find((provider) => !view.selected.includes(provider));
    if (next) return [selectSeat(next)];
    if (view.ready) return [start()];
  }
  if (view.pending && view.stage) return [exchange()];
  return [idle()];
});

export const arenaAcceptsLiveReplies = always(() => !state.current.startupError && !state.current.error);
export const finalReportIncludesAllSeats = always(() => !state.current.report || state.current.finalSeats.length === 3);
