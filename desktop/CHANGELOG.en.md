# Kiteline for Windows and Linux — Release Notes

## 1.0.31 (2026-11-08)

### Improvements

- **GitHub link on the About page**: Settings → About now links to the project on GitHub, so you can leave a star if you like it.

## 1.0.30 (2026-11-07)

### Bug Fixes

- **WeChat Mini Program shown correctly in the device list** (Windows, Linux): Mini Programs paired earlier that appeared as "Browser" are renamed to "WeChat Mini Program" the next time they connect.
- **Claude's questions always show their options**: In some sessions, when Claude asked a question, only an "Input needed" card with no options was shown. The full question and its options are now shown so you can answer directly, and "Allow" on a confirmation card is no longer taken as an answer to a question. Applies to sessions opened or resumed after updating.
- **Let the computer translate messages**: A new "Computer translation" service is added and used first in Auto mode. When connected to a Mac, it translates with System Translation on the Mac; a Windows or Linux computer translates online on your behalf, with a more reliable connection.
- **More reliable message translation**: When the selected translation service cannot be reached, is rate-limited or runs out of free quota, the other service is used automatically instead of failing every message.

## 1.0.29 (2026-11-07)

### Bug Fixes

- **No more empty sessions in the list** (Windows, Linux): Sessions opened in the editor on your computer but never used, and blank sessions left behind when a new session could not be submitted, used to appear in the list with no content. They now appear only after the first message is sent.

## 1.0.28 (2026-11-06)

### New Features

- **Message translation** (Windows, Linux): A new Translate button under each message translates it into the language you choose; click Original to switch back. Hovering over Translate also shows the settings button. The first time, choose the source language (detected automatically by default), the target language, and the translation service (Google Translate or MyMemory, with no sign-up or key required; in Automatic mode, MyMemory is used when Google Translate is unavailable). Change them anytime from the settings button next to the message or in Settings > General. Code blocks, inline code, and links stay unchanged, and tables are translated cell by cell. Turn on Automatically Translate Replies to have replies in a different language translated as they appear on screen. Translate is also available in the right-click menu.

### Bug Fixes

- **Chinese input methods such as Sogou now enter text on Windows** (Windows): For some users typing with Sogou or similar Chinese input methods, the candidate window appeared but the chosen characters were not entered into the message box. Chosen characters are now entered correctly in every text field.
- **No extra English notice after sending a command from your phone** (Windows, Linux): After you sent a slash command (such as changing the effort level) to a Claude Code session from your phone, an extra notice beginning with "local-command-caveat" appeared in the conversation as if you had sent it. It no longer appears.

## 1.0.27 (2026-11-05)

### New Features

- **CodeBuddy / WorkBuddy and ZCode support** (Windows, Linux): When Tencent's CodeBuddy Code or WorkBuddy, or Zhipu's ZCode, is installed on your computer, Kiteline installs the matching plugin automatically. You can follow their sessions on your phone (status, full conversation, task lists), and Today's Usage and the Usage page count their tokens. On Linux, when CodeBuddy Code runs in tmux, you can also send messages, allow or deny commands, answer questions, interrupt and close sessions; the WorkBuddy desktop app and sessions on Windows are view-only.
- **Antigravity and Muse Code support** (Windows, Linux): When Google Antigravity or Meta Muse Code is installed on your computer, Kiteline installs the matching plugin automatically. You can follow their sessions on your phone (status, full conversation), and Today's Usage and the Usage page count their tokens. On Linux, when the Antigravity CLI or Muse Code runs in tmux, you can also send messages, interrupt and close sessions, and for Antigravity allow or deny commands and answer questions (confirm Muse Code's commands on your computer); sessions in the Antigravity desktop app and IDE, and sessions on Windows, are view-only.
- **trae-agent support** (Windows, Linux): When ByteDance's open-source trae-agent CLI is installed on your computer, Kiteline installs the matching plugin automatically. You can follow its tasks and full records on your phone, and Today's Usage and the Usage page count its tokens; on Linux, when it runs in tmux, you can also send tasks from your phone. trae-agent itself has no approvals or questions and can't interrupt a running task. The Trae IDE keeps its chat data encrypted, so it isn't supported.
- **Control Antigravity on Windows from your phone** (Windows): When the Antigravity CLI runs in a Windows terminal, you can reply, allow or deny commands, answer questions, interrupt and close sessions from your phone, no tmux needed. Other command-line agents on Windows will follow as each is tested.
- **Control ZCode from your phone** (Windows, Linux): With models added using an API key, send messages to Zhipu ZCode sessions from your phone; commands to confirm and questions to answer in that turn show up on your phone, and you can interrupt it. Quit and reopen ZCode on your computer to see that turn there. Sessions using a model from your ZCode account sign-in are view-only on your phone. Turns started in the ZCode window on your computer are still confirmed there, as noted in the conversation.
- **Clearer plugin notes** (Windows, Linux): In Settings → Plugins, each plugin now lists the features it can't offer (with the reason) and the ones not yet tested, so you know what it can and can't do from your phone before turning it on.

### Improvements

- **Floating session list** (Windows, Linux): The session list on the left of the main window now floats as a rounded panel, inset from the window edges and the content on the right, with a soft shadow — matching the sidebar style of the latest macOS. Drag the gap between the panel and the content to resize the list, or drag the gap along the top to move the window; any list width you set before is kept.

## 1.0.26 (2026-11-04)

### New Features

- **Kimi Code, Hermes and Grok Build support** (Windows, Linux): When Kimi Code (Moonshot AI), Hermes (Nous Research) or Grok Build (xAI) is installed on your computer, Kiteline installs the matching plugin automatically. You can follow their sessions on your phone (status, full conversation, task lists); on Linux, when they run in tmux, you can also send messages, allow or deny commands, answer questions, interrupt and close sessions (view-only on Windows). Today's Usage and the Usage page count their tokens (and Hermes's spend); turn on "Show plan quota" under the Kimi Code plugin to see your Kimi Code quota and booster balance.
- **Run Claude Code in the background on remote computers instead of opening VS Code** (Windows, Linux): When you start a new task or resume a session on a computer connected over SSH, Kiteline can run Claude Code in the background on that computer instead of opening a VS Code window here, which also reduces VS Code's memory use. It is turned on per computer and is off by default: in Settings → Sources, click Background… next to that computer, or tap the "This session can run Claude in the background" tip at the top of a session, then check the outbound IP and turn it on once the location, network and proxy look right. Claude Code running in the background runs on the computer where the project is, with the same network settings as Claude Code in VS Code (proxy, certificates, API address). They are verified before every launch, and if they can't be confirmed the session opens in VS Code and Kiteline tells you why. Once on, sending messages, approving and closing never bring anything to the front and work even while this computer is locked; the session keeps running on that computer after SSH disconnects or this computer sleeps. A session already open in VS Code can be moved to the background in one step, and clicking "Open in VS Code" while Claude is idle moves the conversation back to VS Code. A new "claude" tab in the session terminal shows the session's original interface, which you can use directly; you can also watch and use it live by running python3 ~/.ccpulse/ccpulse-watch.py attach in a terminal on that computer. The tip in sessions can be turned off with "Don't Show Again". It also works on computers where Claude Code has only been used in VS Code, without a separate command-line install; Windows computers aren't supported yet.
- **Acting from your phone no longer interrupts your work on the computer** (Windows, Linux): When you send a message, approve or deny a command, answer one of Claude's questions or stop a reply from your phone, Kiteline now hands it straight to the Claude Code session instead of bringing VS Code to the front to paste and press keys. Typing on the computer and using other apps are no longer affected, and messages can be sent even while the computer is locked. When Claude is waiting for your approval, VS Code still shows the prompt as usual; answer it on either your phone or the computer and the other one closes. Messages you send from your phone meanwhile are delivered after the approval. A message sent while Claude is working reaches it as soon as it finishes its current step, just like typing on the computer while it works, instead of waiting for the whole reply to finish. Such messages appear in the Kiteline conversation as usual but are not shown separately in VS Code. When you answer a question, Claude receives the options you picked as they are. In VS Code, messages sent from your phone are labeled "Prompt from the kiteline plugin". This applies to Claude Code sessions started or resumed after updating Kiteline, both in VS Code and in a terminal; sessions that were already open before the update keep using the previous method. Sessions running in a terminal can now be answered from your phone without tmux, and VS Code sessions opened on this Linux computer from another computer over Remote-SSH, which could only be operated from the computer showing the VS Code window, can now be sent to directly by Kiteline on this computer.
- **Start a new task in any folder** (Windows, Linux): The project list in New Task now ends with "Open Other Folder…", so you can pick a folder you haven't used with Claude Code yet (for example, a project you just created) and start a session there. On this computer you choose it in the standard folder picker. For computers connected over Remote-SSH, you browse their folders level by level in Kiteline, with filtering, hidden folders and New Folder; Git repositories are marked. New Task in the latest iPhone app can browse this computer's folders the same way.

### Improvements

- **iPhone Live Activities show which command is waiting** (Windows, Linux): When a session on this computer is waiting for you to approve a command, the iPhone Lock Screen and Dynamic Island used to show only "Permission requested". They now show the command itself, for example "Bash: npx prisma migrate deploy".

### Bug Fixes

- **World mode and Flow Board text in English** (Windows, Linux): With the interface in English, the controls help, button tips and chat box in World mode were still shown in Chinese; they now follow the interface language. Counts of one are no longer pluralized (such as "1 sessions"), the panel titles at the bottom of the Flow Board no longer repeat, and tool lane names no longer overlap their bars.
- **Steps on the read-only page no longer repeat the tool name** (Windows, Linux): Steps in your teammate's browser used to read "Bash · Bash: npm test". They now read "Bash: npm test".

## 1.0.25 (2026-11-03)

### New Features

- **Agents can reply with a web page** (Windows, Linux): When a conclusion is easier to follow as a chart, comparison table or flow diagram, the agent can write it as a web page and send it to the conversation. It appears as a card with a title and a short summary and is also sent to your phone; click the card to open it in your default browser. Kiteline updates its screenshot skill automatically so agents know when a web page is the better reply.
- **Prompt links** (Windows, Linux): Opening a Kiteline prompt link opens New Task with the prompt filled in, and selects the project named in the link if it exists on your computer. Nothing runs until you confirm it. Right-click a message you sent and choose Copy as Prompt Link to share a request with a teammate or paste it into a pull request comment. Kiteline registers kiteline:// links automatically when it starts.
- **iPhone Live Activities** (Windows, Linux): While agents on this computer are working or waiting for approval, your paired iPhone shows the session title and status live on the Lock Screen and in the Dynamic Island; tap to open that session. Requires Kiteline 1.8 or later on iPhone, and can be turned off in the app under Settings → Push Notifications. Apple does not allow Live Activity content to be encrypted, so session titles and status are sent in plain text through the Apple Push Notification service; conversation content is never sent.
- **Share a read-only link** (Windows, Linux): Choose Share Read-Only Link… in the session menu to create a local network address for a teammate. Anyone on the same network (Wi-Fi) as the computer can view the session's conversation and the steps taken in a browser without installing Kiteline (thinking, images and key information are left out), and their page updates automatically as the session progresses. The page and its content come straight from the computer and never pass through any server. Links last 1 hour, 24 hours or 7 days, and you can stop sharing at any time.

### Improvements

- **Refresh Today’s Usage at any time** (Windows, Linux): A refresh button next to the Today’s Usage title reloads every computer's plan limits and today's usage on the spot. Claude Code and Codex report their limits with each reply, so a computer that hasn't been used for a while keeps its last reading.

## 1.0.24 (2026-11-03)

### Bug Fixes

- **Images in test reports no longer show as gray boxes** (Windows, Linux): On Windows, agents could not find the browser installed on the computer, so web test reports could not be rendered as images, the first overview image stayed a gray box in the conversation, and web page screenshots failed. Agents now use the installed Microsoft Edge or Google Chrome to render complete reports and screenshots. SVG images sent by agents are also converted to regular images before they are shown, and images sent earlier that showed as gray boxes now display normally too.
- **Images retry automatically when they fail to load** (Windows, Linux): Images in conversations, to-dos, favorites, and Today that failed to load because of a network interruption or a busy computer used to stay gray. They now reload automatically after a moment, and if several attempts fail, the image shows "Tap to Retry" so you can reload it with one click.
- **Flow board cards no longer flash black when a session joins** (Windows, Linux): When a new session joined and the session column was rearranged, session cards briefly showed as black bars with no text. They now show their content right after the rearrangement, and the board no longer flickers when it opens.

## 1.0.23 (2026-11-02)

### Improvements

- **No more brief "computer offline" during plugin updates** (Windows, Linux): When Kiteline installs or updates an agent plugin automatically, or you turn a plugin on or off in Settings → Plugins, the plugins have to be reloaded. Previously, for a few seconds during the reload your phone showed the computer as offline, the session list was emptied, and messages or actions sent in that window failed. Now sessions stay visible and the computer stays online throughout; messages and actions sent in the meantime are carried out as soon as the reload finishes, and actions already in progress are completed first.
- **More ways to paste images** (Windows, Linux): In the message box, New Task and To-Dos, you can now paste screenshots with Shift+Insert and the right-click Paste command as well as Ctrl+V. On Windows, images captured with the PrintScreen key and other sources that previously could not be pasted now paste correctly, and image files copied in File Explorer or your file manager are attached as images when pasted. When the copied content also includes text (for example, Excel cells), it is still pasted as text.

### Bug Fixes

- **Pasting no longer freezes Kiteline** (Windows, Linux): Pressing Ctrl+V in the message box, New Task or To-Dos could make Kiteline stop responding, leaving force-quit as the only option, when the clipboard was in use by another program (Windows) or when pasting content copied from another program (Linux). Pasting no longer blocks the window, and if the clipboard is briefly in use, the paste completes automatically a moment later.

## 1.0.22 (2026-11-02)

### New Features

- **Getting Started guide** (Windows, Linux): The first time you open Kiteline, a four-step guide appears. Step 1 explains that Kiteline is a companion for coding agents and checks which agents are installed on this computer (Claude Code, Codex, OpenCode and more). If none are found, it explains what to install first and links to the VS Code download; if your agent isn’t listed, you can send us its name and a note so we can prioritize support. Step 2 checks your setup (items that aren’t ready explain how to fix them, and some can be installed with one click) and lets you start Kiteline automatically. Step 3 shows a QR code for the iPhone app, then a pairing QR code and code, and confirms as soon as your phone is paired. Step 4 explains the virtual screen and lets you turn it on. Reopen it anytime from Settings → About or the main window’s welcome page.
- **Goals (/goal)** (Windows, Linux): Claude Code (2.1.139 or later) and Codex sessions in the terminal can now be given a goal. The agent keeps working toward it across turns, checks at the end of each turn whether it has been met, and stops only once it is confirmed, which suits long tasks you want the agent to push forward on its own while you're away from your computer. Click Goal below the input box in a conversation to set one; whatever you've already typed in the input box becomes the goal. You can also open it from the session menu, with multi-line and voice input. Once set, the session list shows progress such as Goal · round 3, and above the input box the conversation shows the goal, the current round, the time spent and the result of the latest check; click it to see details, clear or replace the goal, and pause or resume Codex goals. Each check result is also marked in the conversation. You're notified when a goal is achieved, can't be achieved or stops along the way (for example after an API error or when a usage limit is reached); while a goal is in progress you no longer get a separate Completed notification at the end of every turn. Goal progress is also shown for Codex desktop app and VS Code extension sessions; goals for those are set in Codex.
- **Cursor support** (Windows, Linux): When Cursor is installed on your computer, Kiteline installs the Cursor plugin automatically. You can view Cursor editor and CLI agent chats on your phone (status, full history, diffs and task lists), send messages, allow or reject commands and stop tasks. For idle editor chats, Kiteline brings the Cursor editor window for that project to the front to send, then switches back to the app you were using. Chats in the Agents window or in remote workspaces explain why they can't be controlled; on Windows, CLI agent chats are view-only (no tmux). Turn on Show monthly usage under Cursor in Settings → Plugins to see Cursor's usage this month under Today’s Usage.
- **Usage stats now include every agent** (Windows, Linux): Tokens, requests and spend in Today’s Usage and on the Usage page used to count Claude Code only. They now also include Codex, OpenCode, DeepSeek Harness, Qwen Code, Proma and Cursor (for Cursor, turn on Show monthly usage under the plugin), and the Usage page adds a By Agent breakdown. Spend comes from each agent's own records; agents and models that don't record spend are marked Tokens only instead of showing $0. The daily spend alert and spend cap now count spend recorded by all agents.

### Improvements

- **Dialogs now share one style** (Windows, Linux): All in-app dialogs (Goal, Session Info, New Task, confirmations, image viewer, update prompts and more) now have a title bar with the title on the left and maximize and close buttons on the right. Windows uses the system buttons; on Linux they follow your GNOME setting and may appear on the left. Maximize fills the screen and clicking again restores it. Drag the title bar to move the dialog, or double-click it to maximize or restore.
- **Exchanges between sessions no longer notify you** (Windows, Linux): When a session replies to a message from another session (including another session's post in a session group), you no longer get a Completed notification, and images sent during that turn are no longer pushed; the reply is still in the conversation. You are still notified when the session stops on an error or needs your confirmation, and when you also messaged the session during that turn. The screenshot skill and the session group instructions have been updated to match: when replying to another session, a session replies only to the sender and no longer sends you a separate report.
- **Flow board now sits on a grid canvas** (Windows, Linux): The flow board background is now a canvas with a two-level grid of small and large squares. Grid lines stay crisp as you zoom, and the small squares fade out as you zoom out. The star decoration in the old background has been removed.

### Bug Fixes

- **Slash command output no longer shows stray tags** (Windows, Linux): After running a slash command such as /model in Claude Code, the output shown in the conversation used to include a “<local-command-stdout>” tag. It's now removed.
- **Your messages in session groups now use the same font as sessions** (Windows, Linux): Messages you sent in a group chat used a fixed text size and tighter line spacing, so they looked different from messages in a session. They now match sessions, follow the text size set in Appearance, and can be selected with the mouse.
- **Kiteline skill commands now run for Codex and other agents on Windows** (Windows): When Codex and similar agents ran skill commands such as screenshots, to-dos and task progress in PowerShell, the command failed because PowerShell did not accept how it was written, and the agent had to rewrite it and try again. The same command now runs as is in PowerShell, Command Prompt and Git Bash.

## 1.0.21 (2026-11-02)

### New Features

- **Flow board** (Windows, Linux): A new Flow button next to the globe at the top of the sidebar puts every session on one screen: on the left, what sessions read (your requests, project files, memory, web pages, command output); in the middle, each session and its current stage; on the right, what sessions do (explore, edit, run and test, collaborate) and where the results go (changed files, check results, commits and pushes, messages to you and other sessions, plan progress). Every tool call draws a faint line across the columns; when a call happens, a stream of glowing dots flows along it and lights the line up; sessions that are working keep a few dots drifting slowly between calls, while idle sessions stay still. Four live panels at the bottom show call and thinking waveforms, call volume by tool, a model and context overview, and test and build results per session, and every call lights them up. The camera directs itself by default, panning and zooming to a busy card and listing the latest calls that passed through it (what was done, on what, by which session) before returning to the overview; you can drag and zoom, click a card to show only its links, and click a session card to open that session. Press Ctrl+Shift+D to open or leave it; on Linux it opens in a separate window.
- **Usage limits that match each agent's billing** (Windows, Linux): Besides the 5-hour and weekly limits of Claude Code and Codex, the Today’s Usage card in the sidebar and the Plan Limits section of the usage page now show your DeepSeek account balance in DeepSeek Harness (including bonus balance), and support monthly and daily limits: each agent shows as many bars as it has periods, ordered 5-hour, today, this week, this month. Requires signing in to a DeepSeek account in DeepSeek Harness; the balance isn't shown when using an API key.
- **Usage limits explained for each plugin** (Windows, Linux): Each plugin in Settings → Plugins now has a Usage limits line explaining whether that agent's limits or balance can be shown under Today’s Usage and where they come from; when they can't, it explains why and where to check them. Plugin features that need to read an agent's sign-in credentials (such as checking Cursor's monthly usage) are off by default and turned on separately below the plugin, with an explanation of what is read before you turn them on.
- **Update reminders** (Windows, Linux): When a new version is available, an update window now opens automatically, showing the version number, how many versions behind you are, and what's new in each version since yours, and you can download and install it right away. Choose Not Now to be reminded again in 24 hours, or select "Don't remind me about this version" to skip that version; you'll be reminded again when a newer version is released. The window opens without taking focus from the window you're using, so typing in other programs isn't interrupted.
- **Your phone and computer remind each other about updates** (Windows, Linux): When Kiteline on a paired iPhone or iPad is older than the version on the App Store, Kiteline on your computer tells you which devices need updating. Your iPhone or iPad also shows when Kiteline on this computer has a new version and what's new, and you can have your computer download and install it in the background, then restart Kiteline on your computer from your phone to finish (requires the version downloaded from the website).

### Bug Fixes

- **Sessions idle since before the update now close on time** (Windows, Linux): Sessions that were already open when you updated to 1.0.20 had their 24-hour countdown restarted from the update, so they were not closed on time. Kiteline now uses the last-viewed times recorded on each of your devices, and sessions not viewed for more than 24 hours before the update are closed at the next check (when VS Code needs to be switched, Kiteline still waits until the computer has been idle for 10 minutes).

## 1.0.20 (2026-11-02)

### New Features

- **Idle sessions close automatically** (Windows, Linux): sessions whose details have not been opened in Kiteline for 24 hours now have their tab on the computer closed automatically and move to History, including marked and pinned sessions, so sessions you no longer use don't tie up the computer or crowd the tab bar. Opening a session's details on any device, or sending a message from them, counts as opening it; messages from other sessions and replies the session makes in the background do not. A running session is closed after its current turn ends, and when VS Code has to be switched, Kiteline waits until the computer has been idle for 10 minutes so it doesn't interrupt you. To continue, open the session in History and send a message; it returns to the session list. This is on by default and can be turned off in Settings → Sessions.

### Improvements

- **Reminders when an agent forgets to report its progress** (Windows, Linux): with Install Task Stage Skill turned on, Kiteline also installs a small plugin for Claude Code. When Kiteline sees that the agent has moved on to the next step (for example, it has started testing, or has said what it will do next) without reporting it, it reminds the agent to report after its next action; when the agent has been changing code for a while without planning its steps, it reminds it to plan them. Reminders are shown only to the agent, not in the conversation, and take effect in newly started Claude Code sessions.
- **Group chats join the session list and open in tabs** (Windows, Linux): Group chats no longer sit above the session list. They now form their own group in the list, below the filters and ahead of the sessions. When you filter by device, project or status, or search, only groups with members in the results are shown, and search also matches group names. A group chat opens just like a session: as a tab on the right that can sit side by side with sessions, be dragged to any side to split, or be opened from the context menu with "Open in Split on Right" or "Open in Split Below". The tab bar lets you mark the group and show its members; other actions are in the "⋯" menu. Drop a session in the middle of a group chat to add it to the group, or near an edge to split as usual. A new tab's "Choose a session" list also includes groups that aren't open yet. When a group is disbanded, its tab closes automatically.
- **Group chat input matches sessions** (Windows, Linux): The group chat now uses the same input bar as a session. You can send images (by choosing them, pasting a screenshot or dragging them in) and use quick replies. The row below the input no longer shows permission mode, model and context; it shows "To all members" instead, where you can pick specific members to send to. Images and files sent in a group are copied to the computer each member runs on and delivered with the message; for members whose sessions are closed, they're delivered when the session is resumed.

### Bug fixes

- **More reliable automatic submission of new tasks** (Windows, Linux): on Windows, when VS Code opened a new window for a new task, keyboard focus was sometimes not in the Claude input box, so pressing Return did not submit the task and you had to press Return on the computer. Kiteline now places the cursor in the input box before submitting. Tasks that Claude finished within a few seconds could also be reported as “could not be submitted automatically”; this has been fixed.
- **More reliable resuming of members in a past group** (Windows, Linux): when a message sent in a past group needs to resume several sessions, Kiteline now resumes them one at a time. Previously, resuming them at the same time could open the second session as a new blank session in the first project's window, and the group message was not delivered. After resuming, Kiteline now checks that the group message actually reached the session and shows the delivery status accurately. If a session tab that VS Code restored on its own after the computer restarted does not accept the message, the message is shown as not delivered with the reason; send it to the group again.
- **Dragging sessions into groups on Windows** (Windows): fixed an issue where dragging a session from the sidebar into a group chat, or onto a group, did not add it to the group when released.
- **Task progress keeps up with the actual work** (Windows, Linux): Previously, when an agent had planned its own steps and reported one of them, then started editing code, running tests or sending screenshots without reporting the next step, the session list and task progress stayed on the earlier step. Now, when these actions clearly match the next planned step (for example, moving from diagnosing to fixing), Kiteline moves on to that step and marks it as detected automatically. Steps still only move forward and never skip a step that can't be recognized. When an agent hands work such as testing to a subagent running in the background, the current step is now also recognized from the subagent's task: for example, it shows Testing while a subagent runs browser tests, instead of staying on Developing.
- **Two or four images in a message sit side by side** (Windows, Linux): When a message had two or four images, the thumbnails used to stack in a single column. They now show in two columns.

## 1.0.19 (2026-11-01)

### Improvements

- **Task progress moved above the input box** (Windows, Linux): while a session is working, a single line above the input box shows the current step, what is being done and how long it has taken. Click it to see all steps: completed steps are checked and struck through, and the current step is highlighted in the theme color. When a task is split into parts (for example, several platforms), each part has its own row, with the steps of the current part listed under it. The task progress card that appeared at the top of the conversation, and the step labels in the pane title and the “Working” line, are no longer shown; step labels in the session list are unchanged.
- **Group chats: New Group button, marking and muting** (Windows, Linux): a New Group button now sits to the right of the Sessions heading in the session list; tap it and pick the sessions to invite (at least two) to create a group. With many sessions, filter them by device or project at the top of the panel; the create button stays pinned at the bottom. Groups can now be marked, muted or disbanded just like sessions: right-click a group or use the menu in the top-right corner of the group chat. Marked groups stay at the top with a star after the name. When an agent posts in a group you get a notification (at most one every two minutes per group), except for muted groups; tap the notification to open the group chat.

### Bug fixes

- **Messages shown as sent although they were not submitted** (Windows, Linux): if another app took the foreground on the computer while a message from the phone or Kiteline was being delivered to a session in VS Code, the text could miss the input box, or the Return key could miss it, and the message was still shown as sent. Kiteline now checks the input box after pasting and after pressing Return: if the text is not there, it pastes again; if it was not submitted, it presses Return once more. If it still fails, Kiteline says so. On Linux, turn on “Read VS Code Dialogs” in the readiness check.
- **Clearer “not delivered” notice** (Windows, Linux): when a sent message never shows up in the conversation, the notice now reads “Not in the conversation yet. Please check on the computer.”

## 1.0.18 (2026-11-01)

### New Features

- **Group chats: sessions talk to each other across devices and projects** (Mac, iPhone, iPad, Windows, Linux): Put several sessions in a group so they can coordinate directly, for example when one session needs to migrate a server that another session is still using. Sessions can be on different computers and belong to different projects. Drag one session onto another in the session list, or choose Start Group Chat from a session's menu, pick the sessions to include and, optionally, describe what they should work on together; that description is sent to all members as the first group message. Each member receives a group briefing (who the members are, which computer and project each one is in, and how to post), and Kiteline relays their messages from then on, with reply instructions attached to every group message. An agent names the group based on the work, and you can rename it at any time.
- **Group chat page**: Active groups appear at the top of the session list. Open one to see every message exchanged and whether each one was delivered, and post in the group yourself, to all members or only to selected ones, by typing or by voice. Tap the Members button in the top-right corner to slide in the member list from the right, showing each session's computer, project and current status; tap Add Members to bring in more sessions. On a computer, simply drag a session from the sidebar into the group chat to add it. Messages to a session that is waiting for your approval are delivered once you respond. If agents exchange a long run of messages, relaying pauses automatically until you choose to continue.
- **Past groups**: When all member sessions are closed, the group becomes a past group. Posting in a past group resumes those sessions in their original projects and catches them up on the group messages they missed, so they can keep working together. In a session's own conversation, group messages appear as cards; tap one to open the group chat.

### Bug Fixes

- **Task progress no longer jumps back and forth** (Windows, Linux): Previously, when an agent alternated between editing code, compile checks and running tests, the step in the session list could flip between Developing and Testing, and when an agent planned its own steps but didn't report them one by one, the step shown could be the wrong one. Detected steps now only move forward, and tasks whose steps were planned by the agent show exactly the step the agent reported; if the agent hasn't reported its progress for a while, Kiteline reminds it to.

## 1.0.17 (2026-11-01)

### Bug Fixes

- **More reliable Chinese input on Windows** (Windows): Previously, after switching between the message box, the terminal, and the search box, input methods such as Microsoft Pinyin could stop entering text until the client was reopened, and the candidate window always appeared at the top of the screen. Chinese input now works everywhere, the pinyin appears where you type, and the candidate window stays next to the cursor.

## 1.0.16 (2026-11-01)

### New Features

- **See each session's progress in the session list** (Windows, Linux): Sessions that are working now show their current step in the accent color before the status, such as "1/4 Researching", "2/4 Developing", "3/4 Testing" or "4/4 Reporting", so when several sessions are open you can see at a glance which ones are working and how far along each one is. Steps are detected from what the agent does, and nothing is shown when it is only answering a question or looking things up: reading code and looking things up is Researching, editing files is Developing, running tests and checking screenshots is Testing, sending screenshots and reports is Reporting, and committing, pushing, installing or deploying shows as Releasing. The new Task Stage skill (Settings → Agent Integration, on by default) has agents plan steps that fit the task at hand (for example, "Reproduce, Locate, Fix, Verify, Report" for a bug) and report each step as they enter it, optionally with a short note on what they're doing; progress carries on when you reply "continue". Tasks done across several platforms or modules go through the steps once per part and show as "●●○ iPhone · 2/4 Developing" in the list, with the dots showing which parts are done. If you and the agent agree on a fixed process, later tasks in the same project keep using it.
- **Task progress in the conversation** (Windows, Linux): When you open a working session or it moves on to the next step, a Task Progress card appears at the top of the conversation, listing the steps, the time spent on each and the agent's note (for tasks split into parts, a table shows the progress of each part). It hides after 8 seconds; click the card to keep it open. Click the step badge in the "working" row to see it again.
- **Terminals inside sessions** (Windows, Linux): A terminal button now appears below the input box. Click it and a terminal slides up from the bottom, inside the session; the number on the button shows how many terminals the session has open. The terminal runs on the computer where the session runs: for projects opened over Remote-SSH, that is the server itself, starting in the project folder with the same environment as the terminal in VS Code. On Windows it uses PowerShell. You can open several terminals and switch between them, with full color, Chinese input, and keys such as Ctrl+C and the arrow keys. Select text and press Ctrl+C or Ctrl+Shift+C to copy, Ctrl+V to paste, or use the right-click menu to copy, paste, and clear; drag the top edge of the terminal to resize it. Programs keep running after you hide the terminal or switch sessions, and the screen picks up where it left off when you reopen it. Press Ctrl+` to toggle the terminal. Opening and closing terminals is recorded in the activity log; what you type is not.

### Improvements

- **Filter projects by device and project in New Task** (Windows, Linux): When you choose a project, Device and Project filters now appear above the list, each showing how many projects it contains; click a selected filter again to show all. The filters appear only when you have more than one device or project. New Task starts with the device and project currently selected in the session list, and if only one project matches, it is selected automatically. Changing the filters in New Task doesn't affect the session list.
- **The code window is now a standard window** (Windows, Linux): The code IDE now has maximize and close buttons in the top-right corner. Windows uses the system buttons, and Linux follows your GNOME button layout. Double-click the title bar to maximize the window, and double-click again to restore it. The current branch and how many commits it is ahead of or behind the remote appear next to the title; click it to open Branches & Sessions.

### Bug Fixes

- **Full project paths in New Task** (Windows, Linux): Projects with long paths could show only the device name in the New Task list. This has been fixed.
- **Messages now reach sessions without a generated title** (Windows, Linux): Claude Code occasionally fails to generate a title for a session; VS Code then names the tab after the first message you sent. Kiteline previously treated such sessions as if no message had been sent yet, showed only the project folder name, and could not deliver messages or confirmations from your phone. The session list now shows that message, and Kiteline correctly identifies the tab before sending. Sessions renamed in VS Code also show their new name.

## 1.0.15 (2026-10-31)

### New Features

- **Code IDE** (Windows, Linux): "Files" and "Changes" in a session now open a code IDE window laid out like VS Code: Explorer, Source Control, Branches & Sessions, and Commit History on the left, with tabbed editors and a status bar on the right. The editor uses VS Code's grammars and color themes (Dark+, Light+) and supports syntax highlighting, find and replace, and change bars next to the line numbers. Press Ctrl+S to save; before saving, Kiteline checks whether the file on the computer has changed so Claude's latest edits aren't overwritten.
- **File management** (Windows, Linux): Create, rename, copy, cut and paste, duplicate, drag to move, upload files, and copy paths. Deleted files go to the Recycle Bin or Trash and can be restored at any time.
- **Git source control** (Windows, Linux): Stage, unstage or discard whole files or individual hunks, and view changes side by side or inline. Commit, commit and push, or amend the last commit; pull, push, fetch and stash. When a merge or rebase runs into conflicts, choose either version, then continue or abort. The commit graph shows each branch in its own color; you can search commits, view commit details, create, switch, merge, rebase and delete branches, create tags, and cherry-pick, revert or reset.
- **See which branch each session is on** (Windows, Linux, iPhone, iPad): Branches & Sessions lists the sessions running on each branch, grouped by worktree. Before you switch branches while sessions are running in the current folder, Kiteline warns you and suggests checking the branch out in a new worktree. iPhone and iPad connected to a Windows or Linux computer get all code IDE features as well.
- **Receive files from your phone** (Windows, Linux): PDF, Excel, Word and other files sent to Claude from WeChat, WeCom and other apps on iPhone or iPad are saved on the computer running the session, and Claude receives their paths and reads them.
- **Open your computer's files on your phone** (Windows, Linux): File paths that Claude mentions in its replies, such as a spreadsheet or report saved to the desktop, can be tapped on iPhone or iPad. Your computer sends the file to the phone for preview or forwarding to another app. Files whose names suggest keys or passwords are only sent after you confirm on the phone.
- **Filter sessions by device and project** (Windows, Linux): Past Sessions and the session list now have Device and Project filters below the status filters: click one to show only that computer's or project's sessions, and click it again to show all. Each shows its session count, and the filters appear only when you have more than one device or project. When you choose a project, Past Sessions lists all of that project's sessions (not only the most recent ones), sorted by date. With All Projects selected, you can still group by project, source and more.

### Improvements

- **Search past sessions by project name and title** (Windows, Linux, iPhone, iPad): Besides conversation text, sessions whose project name or title contains your search term are now listed, with a note showing whether the project name or the title matched. Results appear as soon as you pause typing, without pressing Enter. Searches are about three times faster, and searches that previously timed out with partial results now return everything.

### Bug Fixes

- **Messages sent from your phone no longer end up in VS Code's terminal** (Windows): Previously, if VS Code's keyboard focus was in the terminal, an editor or another panel, a message sent from your phone could be pasted into the terminal. Kiteline now checks the focus before sending a message or choosing a confirmation option, and moves the cursor into the session's input box first when needed. If it cannot, the message is not sent and your phone shows the reason. If VS Code has already asked "Are you sure you want to paste multiple lines of text into the terminal?" for this reason, Kiteline clicks "Cancel" automatically and no longer pushes it to your phone (this also works on Linux once "Read VS Code Dialogs" is turned on in the readiness check). Prompts that appear when you paste into the terminal yourself are not affected.

### Security

- **Claude.ai Artifact links are no longer opened** (Windows, Linux): Opening claude.ai from a network or IP address different from the one you usually use Claude on may get your account flagged. After Claude publishes an Artifact, VS Code opens a preview automatically and asks "Do you want Code to open the external website?". Kiteline now clicks "Cancel" for every Artifact link, whether it is an automatic preview or a link clicked in a session, and no longer pushes these prompts to your phone. This also fixes messages sent from your phone not being delivered while the prompt was open. Sign-in and other links are not affected. On Linux, turn on "Read VS Code Dialogs" in the readiness check first.
- **Claude.ai links in messages are no longer clickable** (Windows, Linux): Claude.ai links in messages, favorites, plans and other content are now shown as plain text, so they cannot be opened by accident.

## 1.0.14 (2026-10-27)

### New Features

- **World mode** (Windows, Linux): Click the pixel globe at the top of the sidebar or press Ctrl+Shift+E to see all your sessions as a pixel-style office campus, just like on Mac. Each coding agent is a server room, each computer is a satellite orbiting the campus, and each session is a blocky character at a desk, with different animations for working, waiting for confirmation, errors, and idle. When an agent replies, a beam travels from its server room via the satellite to the right computer; when sessions message each other, the characters get up and talk face to face. The chat box in the lower-left corner records all replies and conversations, and clicking a character lets you message that session directly. On Windows, the world appears on the right side of the main window: click a character's screen to open that session's conversation side by side, where you can read and reply right away; click a satellite to view device details; click a session in the sidebar and the camera flies to that character. Click "Leave World" in the upper-left corner or press Ctrl+Shift+E again to return to your sessions, and use the button next to it to hide the session list so the world fills the window. On Linux, the world opens in a browser window, and clicking a character's screen or a satellite opens that session or the device details in the Kiteline main window.

### Improvements

- **Faster update notices** (Windows, Linux): Kiteline now checks for updates every hour instead of every 6 hours, so a new release appears at the bottom of the sidebar within an hour.
- **Agent to-dos are closed promptly** (Windows, Linux): Coding agents now mark a to-do as done as soon as they finish it, and close items that are no longer needed with a note explaining why. When an agent sends a screenshot or reports progress while it still has open to-dos, it is reminded to close them, so finished items no longer linger in the list. A session that takes over a to-do recorded by another session, or on another computer, can close it when done; when an agent records a to-do that already exists, it continues with the existing one instead of adding a duplicate. To-dos whose session has ended are labeled "Session Ended" and listed last; you can mark them as done from the context menu or use "Create Session" to continue the work.
- **Group agent to-dos by project or agent** (Windows, Linux): Agent To-Dos now has a View Options menu, just like the session list. Group by source, project or agent; sort by status, recently updated, date added or name; and, if you use several computers, show only one of them. Until you choose otherwise, grouping follows the session list. To-dos stay with their original project and agent even after their session ends.

## 1.0.13 (2026-10-27)

### New Features

- **Alerts When VS Code Shows a Dialog** (Windows, Linux): When VS Code shows a dialog that needs your attention — for example, Remote-SSH cannot connect, “Workspace does not exist” because a remote folder is temporarily unavailable, or a save prompt before closing — Kiteline sends the dialog text to your phone and shows it at the top of the session list on iPhone until the dialog closes. Nothing is sent while you are using the computer. For connection-related dialogs, tap Try Reconnecting on your phone: Kiteline presses Retry in the dialog for you, or closes the dialog and reloads the window when there is no such button. On Linux, first turn on Read VS Code Dialogs in the readiness check: VS Code then starts with accessibility enabled (the editor works as usual) and uses its own dialog style. This takes effect after you close all VS Code windows and reopen them.
- **Alerts When a Connected Computer Goes Offline** (Windows, Linux): If Kiteline loses its connection to a computer connected over SSH for more than a minute (its sessions temporarily disappear from the list), your phone gets a notification and the reason is shown at the top of the session list on iPhone. Tap Try Reconnecting to reconnect right away; you are notified again once it is back. You can also press and hold the Lock Screen notification and choose Try Reconnecting.
- **Web Test Reports** (Windows, Linux): After finishing or fixing a web feature, Claude uses Playwright to walk through it in a real browser the way a user would, takes a screenshot at every step, and sends a test report designed for reading on your phone. Kiteline installs this skill automatically for the coding agents on this computer and on computers connected through Remote-SSH; you can turn it off in Settings. If a project does not use Playwright, it is set up in Kiteline's own folder without changing your project.
- **To-Dos and Key Info** (Windows, Linux): To-dos are now split into My To-Dos and Agent To-Dos, shown separately. For things only you can do, such as registering an account or getting an AppID or a key, the coding agent reminds you: choose Handle Now, or Add to To-Dos to deal with it later. When you are done, click Back to Session to return to the original session and tell the agent. Work the agent will do later itself goes into Agent To-Dos and is handled by the agent; you can see which session is handling it and how far it has got. If no session is working on it, choose Create Session from its context menu to open a new session with the task and the original project already filled in, and start it once you have confirmed. When an agent gives you information you will need later, such as accounts, passwords or keys, it sends a separate Key Info card: each item can be copied on its own, passwords stay hidden until revealed, and click Save to add the card to Favorites.
- **Mark Sessions** (Windows, Linux): When you are running many tasks at once, mark the sessions you need to keep an eye on, such as ones paused while waiting. Marked sessions show a star in your theme color and appear at the top of the session list, regardless of grouping. A new Marked filter at the top of the session list shows only marked sessions. Click the star that appears when you point at a session, use its context menu, or click the star in the session's tab bar to mark it; click again to unmark. Marks are removed automatically when a session is closed or ends. Marking this computer's sessions on iPhone works the same way.
- **Agent Details and Device Details** (Windows, Linux): Click the agent's avatar in a session (or choose Agent Details… from the session's context menu) to see Agent Details and change the agent's avatar and nickname: upload a picture, or choose the agent's logo, the kite, the first letter of the nickname or one of many emoji, with a background color. Use it for this session only or for every session of that agent. Click ⓘ under Sources in Settings, or the CPU and memory in a group header when the session list is grouped by source, to see device details for this computer and for computers connected through Remote-SSH: IP address, operating system, processor, memory, disk, live usage, and which coding agents are installed and their versions. This also works from an iPhone or iPad connected to the computer; avatars and nicknames are stored on this computer and stay in sync on every device connected to it.

### Improvements

- **Skills for More Coding Agents** (Windows, Linux): The screenshot, web test report, and to-do and key info skills are now installed for Claude Code, Codex, OpenCode, DeepSeek Harness and other coding agents on this computer and on remote computers. Skill content can be updated online without updating Kiteline.
- **Images Read by Claude Shown Inline** (Windows, Linux): When Claude reads an image or takes a screenshot, the image now appears as a thumbnail right below that step, so you no longer need to open the step to see it. Open it to go through every image in that group of steps.
- **Swipe Between Images** (Windows, Linux): When viewing an image, swipe left or right with two fingers on the touchpad, scroll sideways, or drag the image sideways to go to the previous or next image.
- **Message Rope in Split View** (Windows, Linux): When two sessions are open side by side, both copies of a letter, the sender's and the receiver's, are connected by a rope that hangs naturally. When the other letter scrolls out of view, the rope attaches to the top or bottom edge of its column to show whether it is above or below. As each column scrolls, the rope stretches and sways; you can drag the rope and it springs back when released. The rope stays faint so it does not get in the way, and becomes clear when you point at either letter or at the rope. You can turn it off under Messages Between Sessions in Settings.
- **One-Click Copy for Code Blocks** (Windows, Linux): Code blocks, commands, tool input and output, and thinking text show a Copy button at the top right when you point at them. Click it to copy the entire content; the button briefly shows a checkmark.
- **Drag Handle on Split Dividers** (Windows, Linux): When you point at the divider between two panes, a small round handle with arrows appears at the pointer to show that you can drag to resize; it follows the pointer and is highlighted while dragging. Double-click the divider to split evenly again.
- **Skill Settings** (Windows, Linux): Agent Integration in Settings now has separate switches for the screenshot, web testing, and to-dos and key info skills.
- **Sidebar Layout** (Windows, Linux): To-Dos, Projects and Favorites now share one row in the sidebar for a more compact layout. The number on To-Dos counts only your own to-dos; new items an agent asks you to handle appear as a red badge.
- **Leaner Live Sync** (Windows, Linux): When the computer syncs the session list to your phone, it now sends only what changed instead of the full list every time, saving data and battery on cellular and remote access. Takes effect once both the computer and the phone are updated.
- **Sessions Open Elsewhere Are Taken Over Automatically** (Windows, Linux): When a session is still open in a terminal or another window, or a VS Code window has just reloaded, Claude Code reports that the session is still open somewhere else and disables the input box. When you send a message from your phone, Kiteline now chooses Open here anyway and then sends your message. On Linux, this also requires turning on Read VS Code Dialogs first.

### Bug Fixes

- **Images Read in DeepSeek Harness Can Be Viewed** (Windows, Linux): Fixed an issue where opening a step that read an image in a DeepSeek Harness session on your phone showed a file description instead of the image. Also fixed images you send in DeepSeek Harness not loading on your phone.

### Removed

- **To-Dos No Longer Guessed from Replies** (Windows, Linux): Kiteline no longer guesses "things you need to do" from Claude's replies and asks whether to add them to your to-dos. Coding agents now remind you or add to-dos on their own when they are actually needed, so things that are not to-dos are no longer reported as to-dos.

## 1.0.12 (2026-10-25)

### New Features

- **Close Sessions** (Windows, Linux): Hovering over a session card in the session list shows a close button in its top-right corner, and the session context menu includes Close Session. Closing a session also closes its tab in VS Code (terminal sessions are sent /exit), so Claude ends the session and frees up resources on your computer. Closed sessions can be resumed from History. This also applies when you close a session on this computer from iPhone. Codex, OpenCode, DeepSeek Harness and Qwen Code sessions can be closed as well: OpenCode and Qwen Code quit their terminal interface, while Codex (terminal) and DeepSeek Harness sessions are archived there, so you can find them again in each app (OpenCode sessions on Windows aren’t supported yet).

### Bug Fixes

- Fixed an issue where, when viewing multiple images, the Done button was pushed out of the window after the window was narrowed.

## 1.0.11 (2026-10-25)

### Improvements

- **Undelivered Messages Are Flagged** (Windows, Linux): If a message you send doesn't reach Claude (for example, because it's still in the VS Code input), it's now marked as not delivered instead of disappearing silently.

### Bug Fixes

- Fixed an issue where keys typed while Kiteline was delivering a message could land in the VS Code input, leaving the message unsubmitted and merged with the next one. Anything you type during delivery is now passed back to where you were typing once delivery finishes. On the GNOME desktop, Kiteline waits until you stop typing before submitting the message; after updating, sign out and back in once for this to take effect.
- Fixed an issue where, after switching to another app and back to Kiteline, the input field lost focus and had to be clicked again before you could keep typing.

### Security

- Fixed an issue where sending a message while Claude was waiting for your confirmation (allow or deny, or a choice of options) would press Return on the default option in the confirmation. Kiteline now asks you to choose in the confirmation card first, and the message is not sent.

## 1.0.10 (2026-10-24)

### New Features

- **Open Source Licenses** (Windows, Linux): Settings > About now includes Open Source Licenses, which lists the open-source software used by Kiteline along with the full text of each license. You can search by name.

### Improvements

- **DeepSeek Harness Now Turned On Manually** (Windows, Linux): DeepSeek Harness doesn't offer an interface for third-party apps, so Kiteline has to read the connection key it stores on your computer in order to connect. So that you can make an informed choice, this plugin is now off by default, including if you were already using it. To keep using it, open Settings > Plugins, expand How It Connects to review the details, and turn it on. Other plugins are not affected.

## 1.0.9 (2026-10-24)

### New Features

- **Run VS Code on a Virtual Screen** (Windows, Linux): Click the display button in the lower-left corner of the main window, or turn it on from the tray menu or in Settings > General, to move VS Code windows to an invisible virtual screen. When Kiteline sends messages or handles confirmations, VS Code no longer appears in front of you, and focus returns to the app you were using afterward. To view VS Code, click it on the taskbar or dock, or switch to it with Alt+Tab, and that window moves back automatically; messages that are filled in but not submitted, and confirmation dialogs shown by VS Code, also bring the window back so you can see them. Click the button again to move all windows back. Windows return to their original positions when you quit Kiteline, and also if Kiteline quits unexpectedly. On Linux, this requires GNOME 45 or later (such as Ubuntu 24.04): the first time you turn it on, Kiteline installs its GNOME extension, which takes effect after you log out and back in once.
- **Release Notes** (Windows, Linux): Settings > About now includes Release Notes, which show the new features, improvements and bug fixes of each version on a timeline.
- **Screenshot Skill** (Windows, Linux): Kiteline installs a screenshot skill for Claude Code, so Claude tries to include relevant screenshots with its replies and sends them to your phone. You can turn it off in Settings > General > Agent Integration.

### Improvements

- **Automatic Switching to VS Code on Wayland** (Linux): On the GNOME desktop, when Kiteline sends a message from your phone or the client, starts a new task, or chooses an option in a confirmation, it now brings VS Code to the front automatically and switches back to the window you were using afterward, so you no longer need to switch to VS Code first. This requires the Kiteline GNOME extension, which you can install with one click in the readiness check (no administrator password needed); it takes effect after you log out and back in once.
- **Image Viewer Toolbar Matches the Mac Version** (Windows, Linux): The buttons are now at the top of the window, with paging and the title on the left, and zoom; copy, save and open in the default app; and Done on the right. New Copy (Ctrl+C, paste straight into WeChat, Office and other apps), Save… (Ctrl+S) and Open in Default App buttons.
- **Keyboard Shortcuts** (Windows, Linux): Added Ctrl+Y to open History, Ctrl+F to search in the conversation, Ctrl+I for session info, Ctrl+. to interrupt, and Ctrl+Shift+[ / ] to switch tabs, matching the Mac version.
- **Hint When the Receiving Session Isn't in the List** (Windows, Linux): When sessions message each other and the receiving session isn't visible in the sidebar, the bottom of the list shows "To" and the session name. Click it to open the session.
- **Install Updates Later** (Windows, Linux): If you choose Later after a new version is installed, the new version is put in place when you quit Kiteline, so it's ready the next time you open it.
- **Alert When a New Task Isn't Submitted Automatically** (Windows, Linux): If a new task is filled into VS Code but couldn't be submitted automatically, you get an alert asking you to press Return on your computer to submit it.

### Bug Fixes

- Fixed an issue on Windows where pop-up panels couldn't be resized by dragging their edges.
- Fixed an issue on short screens where the title bar of the Settings and Release Notes windows extended past the top of the screen and couldn't be dragged.

## 1.0.8 (2026-10-24)

### New Features

- **Zoom In and Out on Images** (Windows, Linux): The image viewer supports scrolling with Ctrl held down to zoom (pinch to zoom on a touchpad works too) and double-clicking to switch between Fit to Window and Actual Size; once zoomed in, drag to look around. You can also use the zoom buttons at the bottom, or press Ctrl++, Ctrl+-, Ctrl+0 (Actual Size) and Ctrl+9 (Fit to Window). Image files in the Files panel, and screenshots attached in the message box, new tasks and to-dos, can also be clicked to view them larger.
- **Favorites** (Windows, Linux): Right-click a message in a conversation and choose Add to Favorites to save its text and images. Favorites are stored on this computer and are kept even after the session ends or its history is cleared. The sidebar now includes Favorites, where you can search, copy and remove favorites, and click Original Message to jump back to where the message appears in the conversation.

### Improvements

- **Panels Can Be Resized** (Windows, Linux): Files, Changes, Tests, Agent map, Session Info, Search in Conversation, New Task, To-dos and confirmations can be resized by dragging an edge or corner, and moved anywhere by dragging an empty area. Panels opened from a conversation are centered on that conversation (the pane in a split view).
- **Plugins Page Shows Where Each Agent Is Installed** (Windows, Linux): The Plugins page now checks this computer and remote hosts connected through Remote-SSH, and shows which host an agent is installed on. Plugins for agents installed only on a remote host are now installed automatically as well.
- **OpenCode Switch Moved to Plugins** (Windows, Linux): "Install the Kiteline plugin for OpenCode" in Settings > General is now managed by the OpenCode switch on the Plugins page. If you turned it off before, it stays off.
- **New Coding Agents Display Fully Without an Update** (Windows, Linux): Session icons, how the agent is named in conversations, the options on confirmation cards, explanations for view-only sessions, and new kinds of conversation content are now provided by plugins. Supporting a new agent only requires installing its plugin. This also applies to phones and watches connected to this computer.
- **View-Only Sessions Explain Why** (Windows, Linux): When a session is view-only, the message field now explains why — for example, when Qwen Code isn't running in tmux.

### Bug Fixes

- Fixed an issue where session context menus showed Claude Code–only actions such as Permission Mode, Model and Effort, Compact Context and Subagents for Codex and other sessions.
- Fixed an issue where the version and capabilities on the Plugins page did not refresh until the next update check after a plugin was installed, rolled back, or turned on or off.
- Fixed an issue where a plugin version revoked by Kiteline stayed in use. Checking for updates now rolls back to the last working version automatically.

## 1.0.7 (2026-10-24)

### Improvements

- **Updated Plugin Compatibility** (Windows, Linux): The OpenCode plugin has been tested on Windows and Linux, and the compatibility table in Settings > Plugins now marks it as tested.

### Bug Fixes

- Fixed an issue where, after choosing "Restore Built-in Version" on the Plugins page, automatic updates would install the plugin's new version again. Plugins you remove manually are no longer installed automatically, and you can still install them manually from the Plugins page.
- Fixed an issue where plugins could overwrite each other when a remote host connected through Remote-SSH also had Kiteline installed. Plugins synced to a remote host are now stored separately and no longer affect the plugins installed by Kiteline on that host.

## 1.0.6 (2026-10-24)

### New Features

- **DeepSeek Harness Support** (Windows, Linux): In the Kiteline client and in Kiteline on your phone, you can view and control DeepSeek Harness sessions on this computer (the desktop app on Windows, and the command-line version started in web mode on Linux): check work status and the full conversation, send messages and images, approve or reject actions, answer questions and interrupt. DeepSeek Harness approvals apply to a single action only, so confirmation cards do not offer "Allow, and Don’t Ask Again in This Session".
- **View Proma Sessions** (Windows, Linux): While Proma is open, the session list shows recently used Proma sessions, whether they are working and their latest reply, and you can view the full conversation. Proma does not yet offer remote control, so replies and confirmations still need to be made in Proma on your computer.
- **New Plugins Page in Settings** (Windows, Linux): Lists the coding agent plugins Kiteline supports (Codex, OpenCode, DeepSeek Harness and Proma), with each plugin's version, whether its agent is installed on this computer, and what it can do in each form (CLI, VS Code extension, desktop app) on Mac, Windows and Linux: Read (view sessions and history), Write (send messages and add to a running turn), Execute (approve commands, answer questions and interrupt), or Read-only, along with whether it has been tested on that platform. Each plugin can be turned on or off; when turned off, Kiteline stops connecting to that agent and removes the Kiteline components installed in it.
- **Automatic Plugin Updates** (Windows, Linux): Kiteline regularly checks for new versions of official plugins and installs them automatically, so supporting a new coding agent or a new version of an agent no longer requires updating Kiteline. Remote hosts connected through Remote-SSH use the same plugins automatically. Plugins are signed by Kiteline and only verified versions are installed; if a new version runs into problems, Kiteline rolls back to the last working version. If a new plugin requires a newer Kiteline, the Plugins page offers "Update and Install" and installs the plugin once Kiteline has been updated.
- **Error Reports for Plugins** (Windows, Linux): When a plugin runs into a problem, the Kiteline client shows a notice, and you can choose to send an error report from your own email app. The report includes only the plugin and agent versions, your system, and where the error occurred, with no conversation content; you can review it before sending, and it is also copied to the clipboard.

### Improvements

- **No Confirmation Needed When Switching Sessions** (Windows, Linux): When Kiteline switched sessions or started a new task, a newly installed VS Code first asked whether to allow the Claude Code extension to open a link, so messages couldn't get through while you were away from your computer. Kiteline now allows the Claude Code extension to open links automatically. If VS Code still shows a confirmation, Kiteline keeps VS Code in the foreground and lets you know on your phone so you can respond on your computer.
- **Reminder to Trust New Folders When Starting Tasks** (Windows, Linux): When you start a new task from your phone for a project that isn't open in VS Code yet, Kiteline reminds you on your phone that if VS Code opens the project in Restricted Mode, you need to click “Manage” in the banner at the top of VS Code on your computer and trust the folder before the Claude Code extension runs.
- **New Readiness Check: VS Code Allows Claude Code Links** (Windows, Linux): Shows whether Kiteline can switch sessions without VS Code asking for confirmation. If it can't be set up automatically, it lists the steps to take on your computer.
- **Smoother First Use of VS Code** (Windows, Linux): When Kiteline opens VS Code for the first time, it skips VS Code's sign-in welcome screen so it doesn't block your new task.

### Bug Fixes

- Fixed an issue where the context usage of OpenCode sessions was shown as 100% in the session list.
- Fixed an issue where a confirmation shown by VS Code while Kiteline was switching sessions was covered by other windows before you could click it, so it seemed to disappear on its own.
- Fixed an issue where, in the English interface, the result shown after starting a new task or resuming a conversation from your phone didn't read correctly.

## 1.0.5 (2026-10-24)

### New Features

- **Add Remote-SSH Hosts** (Windows, Linux): In Settings → Sources, you can add a Remote-SSH host. Kiteline first checks that you can sign in over ssh without a password, deploys the observer automatically on first connection, and then shows the Claude Code sessions on that host in the session list. Remote-SSH hosts you’ve connected to in VS Code are listed so you can add them with one click. Each source can be renamed, reconnected, disabled or removed.

### Bug Fixes

- Fixed an issue on Windows where connecting to a Remote-SSH host opened a black terminal window that couldn’t be closed.

## 1.0.4 (2026-10-24)

### New Features

- **Kiteline App** (Windows, Linux): A main window that matches the Mac version. The left side shows the session list along with Today, To-Dos, History, Today’s Usage and Projects; the right side shows the full conversation, with split view and multiple tabs. You can reply, approve actions, answer questions, start new and scheduled tasks, and view files, changes, test results and subagents, with dictation, read-aloud, English and Chinese interfaces, and accent colors. Open Kiteline in the tray menu and Kiteline in the app menu both open it.
- **Messages Between Sessions** (Windows, Linux): When Claude Code sessions message each other with SendMessage, a kite flies from the sending session to the receiving one in the session list of the Kiteline app and on iPhone, and dashed lines flowing in the direction of the message link sessions that recently exchanged messages (lines to sessions above run along the left of the avatars, and lines to sessions below along the right). In conversations, these messages appear as letters to or from a session; click the heading to jump to it.
- **Automatic Connection to Remote Projects** (Windows, Linux): When you start a new task or resume a session for a project on a Remote-SSH host, Kiteline connects to the host with VS Code's Remote-SSH and opens the project folder, even if VS Code isn't running yet. If the Remote-SSH extension isn't installed in VS Code, it is installed automatically. If the Claude Code extension isn't installed on the remote host, it is installed there automatically (about 1 minute the first time). On Windows, you no longer need to choose the remote operating system the first time you connect to a host.
- **Update Check** (Windows, Linux): When a new version is available, Download and Install Kiteline appears in the tray menu and a green arrow appears in the top-right corner of the console. Tap it to see what's new. Once you confirm, the update downloads in the background with a progress bar and installs automatically, and Kiteline asks you to restart to start using it. Your settings and paired devices are kept.
- **Start at Login** (Windows): The first time you run Kiteline, Start at Login is turned on. You can turn it off under Start at Login in the console. If you move the Kiteline folder, run Kiteline once more and it will start from the new location at login.
- **Reset Pairing Token** (Windows, Linux): If a phone is lost or a pairing link may have been leaked, you can reset the pairing token in Phone Access. All paired phones are disconnected and stop working immediately, and need to scan the code to pair again.

### Improvements

- **Sending Messages from This Computer** (Linux): When you send a message to a session in VS Code from the Kiteline app, Kiteline switches to VS Code first and returns to your previous window after sending. When VS Code runs natively on Wayland, the system doesn’t allow other apps to switch windows, so Kiteline asks you to switch to VS Code first.

### Bug Fixes

- Fixed an issue where starting a new task for a project on a Remote-SSH host opened a nonexistent folder with the same path on this computer, so no session could be started.
- Fixed an issue where starting a session in a VS Code remote window failed on Linux.
- Fixed an issue on Windows where submitting a new task automatically could add a blank file in VS Code and leave the task unsubmitted.
- Fixed an issue where the same session appeared twice in the session list when a Claude Code session was open in two VS Code windows at the same time.
- Fixed an issue where, after Claude Code automatically compacted the context, the summary of the earlier conversation appeared in the conversation as a message sent by you. It now appears as "Context compacted"; open it to view the summary.
- Fixed an issue where the speech recognition model could fail to download the first time you used voice input, so speech could never be transcribed.
- Fixed an issue where View Full Transcript for a subagent in the Agent map was always empty.
- Fixed an issue where, when a phone used the English interface, notices in conversations such as API errors and interruptions still appeared in Chinese.

## 1.0.3 (2026-10-23)

### New Features

- **English Interface** (Windows, Linux): The tray menu and settings page are available in English. By default they follow the system language (Chinese on a Chinese system, English on any other language). You can also choose a language manually under Language on the settings page; the change takes effect immediately without restarting.
- **Daily Report and Morning Briefing in Each Phone's Language** (Windows, Linux): The daily report and morning briefing are written in the language selected on each phone.

### Improvements

- **More Text in Each Phone's Language** (Windows, Linux): Notices such as a source not being connected also follow the language selected on that phone.

## 1.0.2 (2026-10-23)

### New Features

- **Text in Each Phone's Language** (Windows, Linux): Alerts, status and readiness-check text sent to your phone follow the language selected on that phone, so each phone receives text in its own language. Choose English on the iPhone to see it in English.

## 1.0.1 (2026-10-22)

### New Features

- **Support for Codex and OpenCode** (Windows, Linux): In Kiteline on iPhone, you can view and control OpenAI Codex and OpenCode sessions on this computer. Check work status and the full conversation, allow or deny commands that require approval, answer questions, send messages (including images), or interrupt the current action, without simulated keystrokes. Codex terminal sessions, the VS Code extension, and Codex sessions in the ChatGPT desktop app (Windows) are all supported. Kiteline installs the OpenCode plugin automatically; restart OpenCode to activate it.
- **Computer Status** (Windows, Linux): In Kiteline on iPhone, view this computer's CPU usage and memory use, updated every 5 seconds.

### Improvements

- **New Kite Mark** (Windows, Linux): The app icon, tray icon and console header now use the kite mark that matches the Kiteline app.
- **Return to Previous Window After Sending** (Windows, Linux X11): After you send a message, handle an approval or create a new task from your phone, focus returns to the window you were using rather than remaining in VS Code.

## 1.0.0 (2026-10-22)

### New Features

- **Claude Code on iPhone for Windows and Linux**: View and reply to sessions on this computer through the Kiteline app on iPhone, with the same features as the Mac version.
- **Pairing**: Scan the QR code shown in the console, or enter the 6-digit pairing code on your phone. On the same Wi-Fi network, your phone can discover this computer automatically.
- **Remote Access**: When your phone is not on the same Wi-Fi network, it connects through the Kiteline relay, with end-to-end encryption throughout.
- **Sending Messages**: Supports sessions in VS Code (simulated keyboard input on Windows; X11 and Wayland on Linux) and sessions in the terminal (written directly to the console on Windows; on Linux, requires running in tmux).
- **Wayland Desktop Support** (Linux): Adds the Kiteline companion VS Code extension, provided with Kiteline and installed on this computer. It allows you to send messages, handle approvals and create new tasks for sessions in VS Code on desktops that use Wayland by default, such as Ubuntu 22.04 / 24.04 and Fedora. No keystrokes are sent when the window is not in the foreground, the screen is locked, or the current tab is not the target session.
- **Hold to Talk**: Speech recognition runs offline on this computer using the Fun-ASR-Nano model. The model, about 1 GB, is downloaded on first use.
- **Read Aloud**: Uses Microsoft neural voices by default, which require an internet connection; text to be read aloud is sent to Microsoft's servers for synthesis. On Windows, the system's built-in Chinese voices are available as an offline fallback.
- **Full Feature Set**: Supports lock screen push notifications, To-Dos, Today, Usage, History, Projects and scheduled tasks.
- **Console**: Opens only in a browser on this computer. The entry link is valid for one use only, and the access token does not appear in the address bar, browser history or cookies.
- **Readiness Check**: When components or permissions required for sending messages are missing, the reason is explained, and one-click installation is available (on Linux, apt, dnf, pacman and zypper are supported).
- **Launch at Login**: On Windows, an entry is added to the login startup items; on Linux, a desktop autostart entry is added. Opening Kiteline again only opens the console.

### Improvements

- When a session runs inside a VS Code remote connection (Remote-SSH), a send failure message now explains which computer the editor window is on and how to resolve the issue.
- On Linux, the readiness check now reports a missing xclip or xsel directly.

### Bug Fixes

- Fixed an issue where HTTPS verification failed when the phone connected through the LAN address of a self-built bridge network interface on Linux (such as br-vm or br-lan), because that address was not included in the certificate.
- Fixed an issue where cached images viewed on the phone were not cleaned up. Caches unused for 14 days are now removed automatically.
- Fixed an issue on Windows where, after creating a task from the phone, the content was pre-filled in VS Code but not submitted.
- Fixed an issue on Windows where task content containing characters such as +, & or % was truncated.
- Fixed an issue on Windows where Claude Code in the terminal did not submit received messages, and multi-line messages were split into separate submissions.
- Fixed an issue where, when a project had several sessions and one of them had not yet received a message, that message was pre-filled into a newly opened blank tab.

### Security

- The plaintext HTTP port is open only on this computer. On the local network, only HTTPS is provided, and the pairing QR code uses an HTTPS link.
- The local root certificate can issue certificates only for LAN and local addresses. Slow and oversized requests are disconnected automatically. Pairing is locked by source after too many incorrect pairing code entries. Dependencies are installed from a lock file, and every hash is verified.

### Removed

- The web app is no longer available. Visiting the service address in a browser shows only connection instructions, and “Open Web App” has been removed from the console.
