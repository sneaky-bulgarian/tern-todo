# tern-todo

A fork of [deLiseLINO/tern-todo](https://github.com/deLiseLINO/tern-todo) with a **Jira tickets** tab: the current Jira sprint, one keystroke from an omp session, and closed in Jira when its task is done. Tasks you write yourself go to Jira from their card. More in [tern-plugins](https://github.com/sneaky-bulgarian/tern-plugins/tree/main/tern-todo).

![The Tickets tab lists WEB Sprint 24; Start on WEB-412 opens an omp agent in a new tab, which fixes the bug; Mark as done closes its pane and the ticket shows Done in Jira](https://raw.githubusercontent.com/sneaky-bulgarian/tern-plugins/main/tern-todo/docs/tickets.gif)

The fork also fixes tasks started from a Todo block in a second Tern window: their tabs open in that window, not in the first one.

![Task list and detail card in Tern, dark theme](https://raw.githubusercontent.com/deLiseLINO/tern-todo/341b91aa29ca420e63a285d29772d490217e2672/shots/tasks-dark.png)

## Install

Install [Tern](https://docs.stencil.so/tern/) and Git on the machine that runs the Tern daemon. The plugin runs inside Tern on macOS and Linux.

With a Tern window open, run:

```sh
tern plugin install github.com/sneaky-bulgarian/tern-todo
tern plugin list
```

Check that `todo-proto` is ready and that the window shows no plugin errors.

In the command palette, run **Todo: open tasks**. Or run this command from a terminal in that window:

```sh
tern ctl plugins run plugin.todo-proto.open
```

On the first launch, the plugin creates `~/todos.todo.json`. Later launches use the last selected task file on that host.

## Update

```sh
tern plugin install github.com/sneaky-bulgarian/tern-todo --force
tern plugin list
```

Task files and settings stay intact. If you previously linked a development checkout, run `tern plugin unlink todo-proto` before installing.

## Install on a remote host

Run the installation commands on each remote host that runs Tern. Switch the Tern window to that host, then run **Todo: open tasks**.

For automatic installation on connected hosts, enable **Todo: automatic installation on remote hosts** in the local window's command palette. This installs missing copies only. Update existing copies manually.

## Jira tickets

Open the **Jira tickets** tab (or press `T` on the Tasks tab).

![Connecting Jira, then picking the Acme Web project and its WEB board](https://raw.githubusercontent.com/sneaky-bulgarian/tern-plugins/main/tern-todo/docs/connect.gif)

1. **Connect.** Fill in the form on the right and press **Connect**:
   - **Jira URL**, like `https://your-company.atlassian.net`. A pasted issue or board link is cut down to the site.
   - **Email** and **API token** for Jira Cloud. **Create a token** opens Atlassian's token page.
   - For Jira Data Center, leave **Email** empty and paste a personal access token. It is sent as a Bearer token.

   The plugin checks the credentials against Jira before it saves anything. The token goes to the system keychain (`tern.secrets`, account `plugin.todo-proto.jira.token`). It never reaches the task file, `kv.json` or a link. The URL, email, project and board are kept in the plugin's `kv.json` as `jira`, with the project, component and issue type tasks post to (`jira.post`).
2. **Pick the project, then its board.** A project with a single board picks it for you. The tab then lists the board's active sprint, with each ticket's status and assignee.
3. **Work a ticket.**
   - **Start** (`Enter`, or a double-click) adds the ticket as a task and launches it like any task. omp starts in the last used project with the ticket key, summary, description, long text fields (Definition of Done, Acceptance criteria, any multi-line custom field that holds something) and Jira link as the prompt. The ticket's card shows those fields under the description.
   - **Add to tasks** (`a`) adds the task without starting it, so you can pick the project or model first.
   - Once a ticket has a task, its row shows the task's agent status, and **Go to task** opens it.
4. **Close it.** When a linked task turns done in the plugin, the plugin moves the Jira issue to a done status. That includes the check button, `space`, bulk **Mark done**, and closing the task's pane. It prefers a transition named Done, Closed or Resolved, and fills in a required resolution with Done or Fixed. An issue already in a done status is left alone. If Jira refuses, a toast shows Jira's reason, and the ticket's card offers **Close in Jira** to retry.
5. **Post your own tasks.** While Jira is connected, an open task without an issue gets a **Jira** panel in its card: the draft of its issue. **Post to Jira** creates the issue (title as summary, notes as description) and links the task like a started ticket.
   - **Project**, **Type** and **Component** say where it goes. With nothing saved, they preselect the Jira tickets tab's project (else the first project Jira lists), Jira's default type (Task, else the project's first standard type) and the project's first component. Your first pick or post becomes the default until you pick another; each project keeps its own type and component, and **No component** counts as a pick.
   - Below them come the fields of that type's create screen, read from Jira (`createmeta`) whenever the project or type changes: every field Jira requires (marked `*`), the multi-line custom fields such as **Definition of Done** and **Acceptance criteria**, and priority, labels, assignee, due date and fix versions. **N more fields** shows the rest. Choices (select lists, versions, priority, multi-selects) open a picker with Jira's allowed values; a user field offers **Me**; text, number, date (`YYYY-MM-DD`), date-time (`YYYY-MM-DD HH:MM`, local time) and labels (separated by spaces) are typed in place.
   - Post to Jira checks the required fields first: one left empty or holding something Jira won't take turns red, and a toast lists them. Jira's own refusal still shows as a toast.
   - On a new task, fill in the notes and fields in its card and press **Add and post to Jira** to add and post in one go.
   - If Jira won't describe its create screen (old permissions, an error), the panel says so with **Retry**, and Post to Jira still creates the issue with title, notes and component.

   ![A new task with notes; its card shows Priority, Agent rows and Jira rows (Project Acme Web, Component Checkout) above Add and post to Jira and Add task](https://raw.githubusercontent.com/sneaky-bulgarian/tern-plugins/main/tern-todo/docs/post.png)

**The view.** Under the project and board, **Everyone** / **Only mine** (`m`) narrows the list to tickets assigned to you, and the grouping pill (`s`) groups them by **Assignee** (the default: yours first, then by name, Unassigned last), by **Status** (to do, in progress, done), or not at all. Inside a group tickets keep the board's rank. Click a group's header to fold it; `j`/`k` skip folded groups. The tab's count, the subtitle (`yours: 2 of 6 tickets`) and the selection follow the filter. The view is stored in the plugin's `kv.json` as `jira_view` and shared by every Todos block.

Keys on the Jira tickets tab: `j`/`k` move, `Enter` start, `a` add to tasks, `o` open in Jira, `m` only mine, `s` grouping, `r` reload, `p` project, `b` board, `c` connection, `T` back to Tasks.

Notes:

- Kanban boards have no sprints. Pick a Scrum board, or Jira explains why it cannot list one.
- The window half talks to Jira (`jira.luau`), because only it can read the keychain. A block asks over `todo-jira:` links (`jira-link.luau`), so a Tern window must be open for the tab to load. The machine that runs the window needs network access to Jira.
- On Atlassian's token page, use **Create API token**, not **Create API token with scopes**. Scoped tokens only work through the `api.atlassian.com` gateway, so your site URL answers 401.
- Linked tasks carry `"jira": {"key": "WEB-412", "url": "…/browse/WEB-412"}` in the task file. Values typed into a task's Jira panel stay in `"jira_fields"` (by Jira field id) until it is posted.
