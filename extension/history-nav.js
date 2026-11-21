/* ---------------------------------------------------------------------------
 * 窄屏历史导航
 *
 * 职责只有一件事：在小屏（≤980px）把侧边栏里的历史、查找和页脚收进
 * 顶部条右侧的「历史」抽屉；桌面保持 workspace.css 的完整侧边栏。
 *
 * 不复制 DOM、不维护第二份状态：历史列表、搜索框、计数和连接设置仍是
 * workspace.js 使用的那几个节点，这里只把它们移进一个包裹层。workspace.js
 * 里的节点引用在移动后依然有效，renderHistoryList 也照常工作。
 * ------------------------------------------------------------------------- */

const NARROW_QUERY = '(max-width: 980px)';

const sidebar = document.querySelector('.sidebar');
const toggle = document.getElementById('history-nav-toggle');

if (sidebar && toggle) {
  const historyHead = sidebar.querySelector(':scope > .history-head');
  const search = sidebar.querySelector(':scope > .search');
  const historyList = sidebar.querySelector(':scope > .history-list');
  const sidebarFoot = sidebar.querySelector(':scope > .sidebar-foot');

  if (historyHead && search && historyList) {
    const panel = document.createElement('div');
    panel.className = 'history-nav-panel';
    panel.id = 'history-nav-panel';
    panel.setAttribute('role', 'group');
    panel.setAttribute('aria-label', '历史与查找');

    sidebar.insertBefore(panel, historyHead);
    panel.append(historyHead, search, historyList);
    if (sidebarFoot) panel.append(sidebarFoot);

    const media = window.matchMedia(NARROW_QUERY);
    let open = false;

    const isNarrow = () => media.matches;

    function applyState() {
      const narrow = isNarrow();
      const expanded = narrow && open;

      sidebar.classList.toggle('is-history-compact', narrow);
      sidebar.classList.toggle('is-history-open', expanded);
      toggle.hidden = !narrow;
      toggle.setAttribute('aria-expanded', String(expanded));

      if (expanded) {
        panel.removeAttribute('inert');
        panel.removeAttribute('aria-hidden');
      } else if (narrow) {
        panel.setAttribute('inert', '');
        panel.setAttribute('aria-hidden', 'true');
      } else {
        /* 桌面没有抽屉，历史列表必须保持可读可点。 */
        panel.removeAttribute('inert');
        panel.removeAttribute('aria-hidden');
      }
    }

    /**
     * 关闭后把焦点交给正文标题。只在窄屏、且用户是从抽屉里选中讨论时调用；
     * 打开抽屉时从不移动焦点，键盘用户可以自己决定是否进入面板。
     */
    function focusContent({ attempts = 0 } = {}) {
      if (!isNarrow() || open) return;

      const active = document.activeElement;
      const stillInNav = !active || active === document.body || sidebar.contains(active);
      if (!stillInNav) return;

      /* openSession 先渲染 loading，等它换成正文标题再交还焦点。 */
      if (document.querySelector('#view .loading')) {
        if (attempts < 40) {
          window.setTimeout(() => focusContent({ attempts: attempts + 1 }), 50);
        }
        return;
      }

      const heading = document.querySelector('#view h1');
      const target = heading || document.getElementById('view');
      if (target) {
        if (!target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
        target.focus({ preventScroll: true });
        return;
      }

      if (attempts < 30) {
        window.setTimeout(() => focusContent({ attempts: attempts + 1 }), 40);
      }
    }

    function setOpen(next, { returnFocus = false } = {}) {
      if (!isNarrow()) {
        open = false;
        applyState();
        return;
      }

      const changed = open !== next;
      open = next;
      applyState();

      if (!open && returnFocus && changed) {
        toggle.focus({ preventScroll: true });
      }
    }

    toggle.addEventListener('click', () => {
      setOpen(!open);
    });

    /* 新讨论在顶部条里，不属于抽屉；按下去时顺手收起抽屉，避免遮住正文。 */
    document.getElementById('new-session')?.addEventListener('click', () => {
      if (isNarrow() && open) setOpen(false);
    });

    /* 选中讨论后收起抽屉；workspace.js 自己的点击处理先执行并开始加载。 */
    panel.addEventListener('click', (event) => {
      const item = event.target instanceof Element ? event.target.closest('.history-item') : null;
      if (!item || !panel.contains(item)) return;
      if (!isNarrow() || !open) return;
      setOpen(false);
      focusContent();
    });

    /* 点空白处关闭，不移动焦点。 */
    document.addEventListener('pointerdown', (event) => {
      if (!isNarrow() || !open) return;
      if (event.target instanceof Node && sidebar.contains(event.target)) return;
      setOpen(false);
    });

    /* Escape 只收起抽屉，并回到「历史」按钮；不让它继续关掉页面里的编辑器。 */
    document.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape' || !isNarrow() || !open) return;
      event.preventDefault();
      event.stopPropagation();
      setOpen(false, { returnFocus: true });
    }, true);

    media.addEventListener('change', () => {
      if (!isNarrow()) open = false;
      applyState();
    });

    applyState();
  }
}
