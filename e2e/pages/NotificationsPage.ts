import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/** The kinds of notification, as they appear in an item's test id. */
export type NotificationKind =
  | "task-awaiting-decision"
  | "task-succeeded"
  | "task-failed"
  | "task-canceled"
  | "proposal-ready";

/**
 * The notification center: the bell in the top bar of every workspace page,
 * its panel (what is running now and the inbox) and the page with every
 * notification. Every element is reached by its `data-testid`.
 */
export class NotificationsPage {
  readonly page: Page;
  readonly bell: Locator;
  readonly unreadCount: Locator;
  readonly activityIndicator: Locator;
  readonly panel: Locator;
  readonly activeTab: Locator;
  readonly inboxTab: Locator;
  readonly emptyActive: Locator;
  readonly emptyInbox: Locator;
  readonly markAllRead: Locator;
  readonly seeAll: Locator;
  readonly mineToggle: Locator;
  readonly filterUnread: Locator;
  readonly filterAll: Locator;
  readonly loadMore: Locator;
  readonly closeButton: Locator;
  readonly list: Locator;

  constructor(page: Page) {
    this.page = page;
    this.bell = page.getByTestId("notifications-bell");
    this.unreadCount = page.getByTestId("notifications-unread-count");
    this.activityIndicator = page.getByTestId("notifications-activity-indicator");
    this.panel = page.getByTestId("notifications-panel");
    this.activeTab = page.getByTestId("notifications-tab-active");
    this.inboxTab = page.getByTestId("notifications-tab-inbox");
    this.emptyActive = page.getByTestId("notifications-empty-active");
    this.emptyInbox = page.getByTestId("notifications-empty-inbox");
    this.markAllRead = page.getByTestId("notifications-mark-all-read");
    this.seeAll = page.getByTestId("notifications-see-all");
    this.mineToggle = page.getByTestId("notifications-mine-toggle");
    this.filterUnread = page.getByTestId("notifications-filter-unread");
    this.filterAll = page.getByTestId("notifications-filter-all");
    this.loadMore = page.getByTestId("notifications-load-more");
    this.closeButton = page.getByTestId("notifications-close");
    this.list = page.getByTestId("notifications-page");
  }

  /** A task (by its id) or a proposal (by its job's id) in "Em andamento". */
  activeItem(id: string): Locator {
    return this.page.getByTestId(`notifications-active-item-${id}`);
  }

  /** A notification about a task or a proposal (by its id), of one kind. */
  item(subjectId: string, kind: NotificationKind): Locator {
    return this.page.getByTestId(`notifications-item-${subjectId}-${kind}`);
  }

  /** Opens the panel from the bell, on the running tab. */
  async open() {
    await this.bell.click();
    await expect(this.panel).toBeVisible();
  }

  /** Opens the panel on the inbox. */
  async openInbox() {
    await this.open();
    await this.inboxTab.click();
  }

  async close() {
    await this.closeButton.click();
    await expect(this.panel).toBeHidden();
  }

  /** The page with every notification of the workspace's member. */
  async openPage(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/notifications`);
    await expect(this.list).toBeVisible();
    await waitForLiveView(this.page);
  }
}
