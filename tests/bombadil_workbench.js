import { always } from "@antithesishq/bombadil";
import { actions, extract, registerCustomAction } from "@antithesishq/bombadil/browser";
export {
  noUncaughtExceptions,
  noUnhandledPromiseRejections,
} from "@antithesishq/bombadil/browser/defaults/properties";

const draftText = "Bombadil 合成草稿";

const snapshot = extract(({ document }) => {
  const visible = (element) => element.getClientRects().length > 0;
  const controls = [...document.querySelectorAll("button:not(:disabled)")].filter(visible);
  return {
    question: document.querySelector("#question-input")?.value ?? null,
    selected: controls.filter((button) => button.matches(".provider-option[aria-pressed=true]"))
      .map((button) => button.dataset.providerId),
    controls: controls.map((button) => ({
      text: button.textContent.trim(),
      seat: button.closest(".seat-card")?.dataset.provider ?? "",
      modal: Boolean(button.closest("dialog[open]")),
    })),
    drafts: [...document.querySelectorAll(".seat-card .answer-editor:not(.correction-editor)")]
      .map((editor) => ({
        seat: editor.closest(".seat-card").dataset.provider,
        text: editor.querySelector("textarea").value,
        pressed: Boolean(editor.querySelector(".stance-btn[aria-pressed=true]")),
        voting: Boolean(editor.querySelector(".stance-btn")),
      })),
    checkedCollapse: document.body.dataset.bombadilCheckedCollapse === "true",
    collapseFailed: document.body.dataset.bombadilCollapseFailed === "true",
    clearFailed: document.body.dataset.bombadilClearFailed === "true",
    paused: controls.some((button) => button.textContent.trim() === "继续讨论"),
    stage: document.querySelector(".step.is-current .step-label")?.textContent.trim() ?? "",
    startupError: Boolean(document.querySelector("#global-error:not([hidden])")),
    report: document.querySelector(".report-status")?.textContent.trim() ?? "",
    hasRejection: [...document.querySelectorAll(".report .stance-chip")]
      .some((chip) => chip.textContent.trim() === "反对"),
    overflows: document.documentElement.scrollWidth > innerWidth + 1,
  };
});

const type = registerCustomAction("enter-local-sample", (document, window, seat, text) => {
  const field = seat ? document.querySelector(`.seat-card[data-provider="${seat}"] textarea`)
    : document.querySelector("#question-input");
  if (!field) return;
  field.value = text;
  field.dispatchEvent(new window.Event("input", { bubbles: true }));
});

const click = registerCustomAction("click-arena-control", async (document, window, label, seat, modal) => {
  const scope = modal ? document.querySelector("dialog[open]")
    : seat ? document.querySelector(`.seat-card[data-provider="${seat}"]`) : document;
  const button = [...(scope?.querySelectorAll("button:not(:disabled)") ?? [])]
    .find((item) => item.textContent.trim() === label && item.getClientRects().length);
  if (!button) return;
  const editor = button.closest(".answer-editor");
  if (!modal && label === "清除草稿") document.body.dataset.bombadilClearSeat = seat;
  const clearSeat = document.body.dataset.bombadilClearSeat;
  const draft = editor?.querySelector("textarea")?.value;
  button.click();
  if (label === "收起" && draft?.trim()) {
    const card = document.querySelector(`.seat-card[data-provider="${seat}"]`);
    const closed = !card?.querySelector(".answer-editor");
    const resume = [...(card?.querySelectorAll("button") ?? [])]
      .find((item) => item.textContent.trim() === "继续草稿");
    if (!closed || !resume) {
      document.body.dataset.bombadilCollapseFailed = "true";
      return;
    }
    resume.click();
    document.body.dataset.bombadilCheckedCollapse = "true";
    if (document.querySelector(`.seat-card[data-provider="${seat}"] textarea`)?.value !== draft) {
      document.body.dataset.bombadilCollapseFailed = "true";
    }
  }
  if (modal && label === "清除草稿") {
    await new Promise((resolve) => window.setTimeout(resolve, 0));
    const activeEditor = document.querySelector(`.seat-card[data-provider="${clearSeat}"] .answer-editor`);
    if (!activeEditor || activeEditor.querySelector("textarea").value ||
        activeEditor.querySelector(".stance-btn[aria-pressed=true]")) {
      document.body.dataset.bombadilClearFailed = "true";
    }
  }
});

const select = registerCustomAction("select-manual-seat", (document, _window, seat) => {
  document.querySelector(`.provider-option[data-provider-id="${seat}"][aria-pressed=false]`)?.click();
});

const settle = registerCustomAction("wait-for-workspace", (_document, window) =>
  new Promise((resolve) => window.setTimeout(resolve, 100)));

const newDiscussion = registerCustomAction("start-new-discussion", (document) =>
  document.querySelector("#new-session").click());

const reload = registerCustomAction("reload-arena", (_document, window) => window.location.reload());

const vote = registerCustomAction("select-stance", (document, _window, seat, stance) => {
  document.querySelector(`.seat-card[data-provider="${seat}"] [data-stance="${stance}"]`)?.click();
});

const manualSeats = ["chatgpt", "claude"];
const allowed = new Set([
  "粘贴回答", "继续草稿", "收起", "清除草稿", "刷新状态", "暂停", "继续讨论",
]);

export const workbench = actions(() => {
  const { question, selected, controls, drafts, report, checkedCollapse } = snapshot.current;
  if (question !== null) {
    const missing = manualSeats.filter((seat) => !selected.includes(seat));
    if (missing.length) return missing.map((seat) => select(seat));
    if (!question) return [type("", "Bombadil 合成题：是否先验证需求？")];
    return controls.some(({ text }) => text === "开始讨论")
      ? [click("开始讨论", "", false)] : [settle()];
  }

  const dialogs = controls.filter(({ modal }) => modal);
  if (dialogs.length) return dialogs.map(({ text }) => click(text, "", true));
  if (report) return [newDiscussion(), reload()];

  const filled = drafts.find(({ text }) => text.trim());
  if (filled && !checkedCollapse) return [click("收起", filled.seat, false)];

  const choices = controls.filter(({ text }) => allowed.has(text))
    .map(({ text, seat }) => click(text, seat, false));
  for (const { seat, text, pressed, voting } of drafts) {
    if (!text) choices.push(type(seat, `${draftText}：${seat} 建议优先验证需求。[S1]`));
    if (voting && !pressed) choices.push(vote(seat, "agree"), vote(seat, "oppose"));
    if (text && (!voting || pressed)) {
      const label = voting ? "记录表态" : "提交回答";
      if (controls.some((item) => item.seat === seat && item.text === label)) {
        choices.push(click(label, seat, false), click(label, seat, false));
      }
    }
  }
  if (drafts.some(({ text }) => text)) choices.push(reload());
  return choices.length ? choices : [settle()];
});

export const draftCollapsesAndResumes = always(() => !snapshot.current.collapseFailed);
export const clearResetsTextAndStance = always(() => !snapshot.current.clearFailed);
export const pausedDisablesSubmission = always(() => !snapshot.current.paused ||
  !snapshot.current.controls.some(({ text }) => ["提交回答", "记录表态", "保存更正"].includes(text)));
export const rejectionPreventsUnanimity = always(() =>
  !snapshot.current.hasRejection || snapshot.current.report !== "全体一致");
export const workspaceFitsViewport = always(() => !snapshot.current.overflows);
export const backendRemainsReachable = always(() => !snapshot.current.startupError);
