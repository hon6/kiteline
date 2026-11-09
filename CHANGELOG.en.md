# Kiteline Release Notes

## 3.49.29 (2026-11-09)

### New Features

- **Add other Kiteline computers** (Mac, iPhone, iPad): In Settings → Sources, click Add Kiteline Computer, enter the other computer's address and the code shown on its Phone Access page, then click Allow on that computer. The two computers add each other as sources, and the other computer's sessions appear right in your session list, ready to view, reply to and approve, with actions carried out on the computer the session runs on. Ideal for working across home and office. The computers connect directly (local network, public address or your own mesh network), never through the Kiteline relay. Kiteline computers on your local network are listed automatically; click one to fill in its address.
- **Your phone connects as long as either computer is online** (iPhone, iPad): After pairing with one computer, your phone automatically gets access to the other. If the current computer can't be reached but the other one is online on the same network, the app switches over automatically and still shows every session from both computers. If neither can be reached, it suggests subscribing to Remote Access.
- **pi support** (Mac, iPhone, iPad): When the open-source coding agent pi is installed on your computer, Kiteline installs its plugin automatically. You can follow its sessions on your phone, including status, the full conversation, thinking and tool calls. When pi runs in tmux, you can also send messages (queued automatically while it's busy), interrupt and close sessions. Today's usage and the usage report include pi's tokens and cost. pi never asks for permission itself, so there's nothing to allow or deny.

### Security

- **Pairing codes resist guessing**: A code is discarded and replaced after 5 wrong attempts; pairing from public addresses is paused for an hour after too many failed attempts; and pairing a phone from a public address now also requires confirmation on the computer.

## 3.49.28 (2026-11-09)

### Bug Fixes

- **No more jumping text while typing**: With a mouse connected, the scroll bar in the message box could flicker on and off as the text neared the maximum height, making lines rewrap back and forth. The scroll bar now floats over the text and no longer takes up width. The chat box in World mode is fixed as well.

## 3.49.27 (2026-11-09)

### Improvements

- **Select and copy message text freely** (Mac, iPhone, iPad): Multiple paragraphs, headings and lists in a reply can now be selected in one continuous drag, as in an editor, instead of stopping at each line break. On iPhone, press and hold to select any part; the menu also offers Quote, Add to To-dos, Translate and more. Each message now has a Copy button underneath to copy the whole message.
- **Copy thinking, and collapse long thinking anytime** (Mac, iPhone, iPad): Expanded thinking can be selected and copied, and long thinking has a Hide button at the bottom, so you no longer need to scroll back to the top.

### Bug Fixes

- **Session groups show messages right away** (Mac, iPhone, iPad): Opening a session group could show a blank message list until you scrolled; the latest messages now appear immediately.


## 3.49.26 (2026-11-08)

### Improvements

- **GitHub link on the About page** (Mac, iPhone, iPad): Settings → About now links to the project on GitHub, so you can leave a star if you like it.

### Bug Fixes

- **New Task window fits its content** (Mac): after typing a long task description or attaching images, the window grows automatically so everything stays visible, instead of overlapping the title bar or cutting off the buttons at the bottom. The project list also sizes itself to the number of projects.

## 3.49.25 (2026-11-07)

### Improvements

- **Let your computer translate messages** (Mac, iPhone, iPad): A new "Computer translation" service is added and used first in Auto mode. Your phone hands the message to the connected computer: a Mac translates it on the computer with System Translation (macOS 26 or later with the language pack downloaded), fast and without going online; other computers translate online on your behalf. When System Translation is selected but is unavailable on the phone, the Mac translates it locally instead, so messages are never sent to a third-party service.

### Bug Fixes

- **WeChat Mini Program shown correctly in the device list** (Mac): devices paired with a code now keep the name they report. Mini Programs paired earlier that appeared as "Browser" are renamed to "WeChat Mini Program" the next time they connect.
- **Claude's questions always show their options** (Mac, iPhone, iPad): In some sessions, when Claude asked a question, the phone and computer showed only an "Input needed" card with no options. The full question and its options are now shown so you can answer directly, and "Allow" on a confirmation card is no longer taken as an answer to a question. Applies to sessions opened or resumed after updating.
- **More reliable message translation** (Mac, iPhone, iPad): Automatic translation no longer pops up the system "Download Languages to Translate" window from time to time; you are asked to download a language pack only when you tap Translate yourself. English replies full of technical terms are no longer mistaken for French or other languages. Scrolling away or switching sessions during automatic translation no longer shows a failure; translation resumes when the message is back on screen. When the selected online translation service cannot be reached or runs out of free quota, another available service is used automatically instead of failing every message, and a clear message is shown when System Translation is not available on the device.

## 3.49.24 (2026-11-07)

### Bug Fixes

- **No more empty sessions in the list** (Mac, iPhone, iPad): Sessions opened in the editor on your computer but never used, and blank sessions left behind when a new session could not be submitted, used to appear in the list with no content. They now appear only after the first message is sent.

## 3.49.23 (2026-11-06)

### New Features

- **Message translation** (Mac, iPhone, iPad): A new Translate button under each message translates it into the language you choose; click Original to switch back. The first time, choose the source language (detected automatically by default), the target language, and the translation service; you can change them anytime from the settings button next to the message or in Settings. On Mac, hovering over Translate also shows the settings button. Choose System Translation (on-device, so messages never leave your device; download the language pack right from translation settings to use it offline), Google Translate, or MyMemory, with no sign-up or key required, each described in settings so you can pick; in Automatic mode, Kiteline moves to the next service if one is unavailable. Code blocks, inline code, and links stay unchanged, and tables are translated cell by cell. Turn on Automatically Translate Replies to have replies in a different language translated as they appear on screen. Translate is also available in the message menu, and the button under messages can be turned off in Settings.

### Improvements

- **Smoother Settings window** (Mac): Switching between pages in Settings now resizes the window smoothly instead of jumping. The Plugins page is taller, so you can see more plugins and notes at once.

### Bug Fixes

- **No extra English notice after sending a command from your phone** (Mac, iPhone, iPad): After you sent a slash command (such as changing the effort level) to a Claude Code session from your phone, an extra notice beginning with "local-command-caveat" appeared in the conversation as if you had sent it. It no longer appears.

## 3.49.22 (2026-11-05)

### New Features

- **CodeBuddy / WorkBuddy and ZCode support** (Mac, iPhone, iPad): When Tencent's CodeBuddy Code or WorkBuddy, or Zhipu's ZCode, is installed on your computer, Kiteline installs the matching plugin automatically. You can follow their sessions on your phone (status, full conversation, task lists), and Today's Usage and the Usage page count their tokens. When CodeBuddy Code runs in tmux, you can also send messages, allow or deny commands, answer questions, interrupt and close sessions; the WorkBuddy desktop app offers no external control interface, so it's view-only.
- **Antigravity and Muse Code support** (Mac, iPhone, iPad): When Google Antigravity or Meta Muse Code is installed on your computer, Kiteline installs the matching plugin automatically. You can follow their sessions on your phone (status, full conversation), and Today's Usage and the Usage page count their tokens. When the Antigravity CLI or Muse Code runs in tmux, you can also send messages, interrupt and close sessions, and for Antigravity allow or deny commands and answer questions (confirm Muse Code's commands on your computer); sessions in the Antigravity desktop app and IDE are view-only.
- **trae-agent support** (Mac, iPhone, iPad): When ByteDance's open-source trae-agent CLI is installed on your computer, Kiteline installs the matching plugin automatically. You can follow its tasks and full records on your phone, and Today's Usage and the Usage page count its tokens; when it runs in tmux, you can also send tasks from your phone. trae-agent itself has no approvals or questions and can't interrupt a running task. The Trae IDE keeps its chat data encrypted, so it isn't supported.
- **Control ZCode from your phone** (Mac, iPhone, iPad): With models added using an API key, send messages to Zhipu ZCode sessions from your phone; commands to confirm and questions to answer in that turn show up on your phone, and you can interrupt it. Quit and reopen ZCode on your computer to see that turn there. Sessions using a model from your ZCode account sign-in are view-only on your phone. Turns started in the ZCode window on your computer are still confirmed there, as noted in the conversation.
- **Clearer plugin notes** (Mac): In Settings → Plugins, each plugin now lists the features it can't offer (with the reason) and the ones not yet tested, so you know what it can and can't do from your phone before turning it on.

## 3.49.21 (2026-11-04)

### New Features

- **Kimi Code, Hermes and Grok Build support** (Mac, iPhone, iPad): When Kimi Code (Moonshot AI), Hermes (Nous Research) or Grok Build (xAI) is installed on your computer, Kiteline installs the matching plugin automatically. You can follow their sessions on your phone (status, full conversation, task lists); when they run in tmux, you can also send messages, allow or deny commands, answer questions, interrupt and close sessions. Today's Usage and the Usage page count their tokens (and Hermes's spend); turn on "Show plan quota" under the Kimi Code plugin to see your membership's 5-hour, weekly and monthly quota and booster balance.
- **See how the agent works in the Execution Timeline** (Mac, iPad): Tap the Execution Timeline button in the top-right corner of a session to open the timeline. It takes the top third of the screen, and the conversation continues below it. Drag the divider to adjust the split. The timeline reads from top to bottom through agents, turns and steps, and from left to right through time; idle stretches fold away automatically. It fills the screen width by default, and you can also choose a three-hour, one-hour or fifteen-minute window. Each turn is color-coded by model calls and tool calls, and errors are marked in red; one tap jumps to the first error. Tap a turn's bar to see how its time was split. Replay re-enacts the whole run in about fifteen seconds, Follow keeps the view on the latest progress, and the timeline refreshes live while the session is running.
- **Run Claude Code in the background on remote computers instead of opening VS Code** (Mac, iPhone, iPad): When you start a new task or resume a session on a computer connected over SSH, Kiteline can run Claude Code in the background on that computer instead of opening a VS Code window here, which also reduces VS Code's memory use. It is turned on per computer and is off by default: in Settings → Sources, click Background… next to that computer, or tap the "This session can run Claude in the background" tip at the top of a session, then check the outbound IP and turn it on once the location, network and proxy look right. Claude Code running in the background runs on the computer where the project is, with the same network settings as Claude Code in VS Code (proxy, certificates, API address). They are verified before every launch, and if they can't be confirmed the session opens in VS Code and Kiteline tells you why. Once on, sending messages, approving and closing never bring anything to the front and work even while this computer is locked; the session keeps running on that computer after SSH disconnects or this computer sleeps. A session already open in VS Code can be moved to the background in one step, and clicking "Open in VS Code" while Claude is idle moves the conversation back to VS Code. A new "claude" tab in the session terminal shows the session's original interface, which you can use directly; you can also watch and use it live by running python3 ~/.ccpulse/ccpulse-watch.py attach in a terminal on that computer. The tip in sessions can be turned off with "Don't Show Again". It also works on computers where Claude Code has only been used in VS Code, without a separate command-line install; Windows computers aren't supported yet.
- **Acting from your phone no longer interrupts your work on the computer** (Mac, iPhone, iPad): When you send a message, approve or deny a command, answer one of Claude's questions or stop a reply from your phone, Kiteline now hands it straight to the Claude Code session instead of bringing VS Code to the front to paste and press keys. Typing on the computer and using other apps are no longer affected, and messages can be sent even while the computer is locked. When Claude is waiting for your approval, VS Code still shows the prompt as usual; answer it on either your phone or the computer and the other one closes. Messages you send from your phone meanwhile are delivered after the approval. A message sent while Claude is working reaches it as soon as it finishes its current step, just like typing on the computer while it works, instead of waiting for the whole reply to finish. Such messages appear in the Kiteline conversation as usual but are not shown separately in VS Code. When you answer a question, Claude receives the options you picked as they are. In VS Code, messages sent from your phone are labeled "Prompt from the kiteline plugin". This applies to Claude Code sessions started or resumed after updating Kiteline, both in VS Code and in a terminal; sessions that were already open before the update keep using the previous method. Sessions running in a terminal on computers connected over Remote-SSH can now be answered from your phone without tmux.
- **Start a new task in any folder** (Mac, iPhone, iPad): The project list in New Task now ends with "Open Other Folder…", so you can pick a folder you haven't used with Claude Code yet (for example, a project you just created) and start a session there. On this Mac you choose it in the standard folder picker. For computers connected over Remote-SSH, and on iPhone and iPad, you browse that computer's folders level by level in Kiteline, with filtering, hidden folders and New Folder; Git repositories are marked. Browsing starts from the folder that holds most of your projects.

### Improvements

- **Live Activities show which command is waiting** (iPhone, Mac): When a session is waiting for you to approve a command, the Lock Screen and Dynamic Island used to show only "Permission requested". They now show the command itself, for example "Bash: npx prisma migrate deploy", so you can decide whether to act right away without opening the app.
- **Hover a tab to see its full title** (Mac): When split panes are narrow and tab titles are cut off, rest the pointer on a tab for a moment and it expands to show the full title. Other tabs in the same pane narrow for the moment and the session and split buttons move into More, so nothing spills over the neighboring pane. Everything returns to normal when the pointer leaves the tab bar.

### Bug Fixes

- **World mode and Flow Board text in English** (Mac, iPhone, iPad): With the interface in English, the controls help, button tips and chat box in World mode were still shown in Chinese; they now follow the interface language. Counts of one are no longer pluralized (such as "1 sessions"), the panel titles at the bottom of the Flow Board no longer repeat, and tool lane names no longer overlap their bars.
- **Messages no longer go to a same-named project on another computer** (Mac): When several computers had a project with the same name open (for example, ccpulse), a message for a session on one computer could be delivered to another computer's VS Code window. Claude Code couldn't find the session there and opened a new blank session, and messages between sessions could open several in a row. Kiteline now checks which computer each window is connected to; if the window for the session's computer isn't open, the message isn't sent and you're told why.
- **Clicking another window while a message is being sent no longer makes it fail** (Mac): to deliver a message to VS Code, Kiteline briefly brings VS Code to the front and pastes. A click on another window during those one or two seconds used to take the focus away and the message was not sent. Clicks made during that moment are now held and replayed at the same position once the message is sent and the previous app is back in front (the same way typed keys were already held), so the click takes effect a second or two later.
- **No false error when opening Share Read-Only Link** (iPhone, iPad): If the app happened to be reconnecting to your computer when you opened the panel, it showed "Couldn't load sharing status: cancelled". It now loads the status once the connection is back and no longer shows this message.
- **Steps on the read-only page no longer repeat the tool name** (Mac): Steps in your teammate's browser used to read "Bash · Bash: npm test". They now read "Bash: npm test".

## 3.49.20 (2026-11-03)

### New Features

- **Agents can reply with a web page** (Mac, iPhone, iPad): When a conclusion is easier to follow as a chart, comparison table or flow diagram (such as a performance comparison, data analysis or a choice between options), the agent can write it as a web page and send it to the conversation. It appears as a card with a title and a short summary, and you are notified. On iPhone and iPad, tap the card to open the page in the app, where you can zoom and interact with it and share it from the top-right corner. On Mac, it opens in your default browser. The page runs on its own on the phone and cannot read anything in the app; links in it open in Safari. Kiteline updates its screenshot skill automatically so agents know when a web page is the better reply.
- **Prompt links** (Mac, iPhone, iPad): Turn a task request into a link you can send to a teammate or paste into a pull request comment or a document. When someone opens the link, Kiteline opens New Task with the prompt filled in, and selects the project named in the link if it exists on their computer. Nothing runs until they confirm it. To create one, touch and hold (right-click on Mac) a message you sent and choose Copy as Prompt Link; agents can also create links with a Kiteline command. On an iPhone with Kiteline installed, the link opens the app directly; on a computer, it first opens a web page that shows the prompt and opens it in Kiteline with one click. The prompt is kept after the “#” in the link and is never sent to our servers.
- **Live Activities** (iPhone, Mac): While agents are working or waiting for approval, the session title and status appear live on the iPhone Lock Screen and in the Dynamic Island. Sessions waiting for approval are listed first, along with the command they are waiting on; working sessions show the current step (such as "2/4 Developing"); sessions that just finished or stopped on an error are listed too. When collapsed, the Dynamic Island shows how many sessions are waiting or working, and the kite turns orange when something needs your approval. Tap to open that session. The app does not need to be open: your computer starts, updates and ends the Live Activity through push notifications. Once every session has stopped, it shows "All done" and disappears a few minutes later. If you swipe it away on the Lock Screen, it stays hidden until the current round of work ends. You can turn it off in the app under Settings → Push Notifications. Apple does not allow Live Activity content to be encrypted, so session titles and status are sent in plain text through the Apple Push Notification service; conversation content is never sent.
- **Share a read-only link** (Mac, iPhone, iPad): Choose Share Read-Only Link in the session menu to create a local network address for a teammate. Anyone on the same network (Wi-Fi) as your computer can view the session's conversation and the steps taken in a browser without installing Kiteline (thinking, images and key information are left out), and their page updates automatically as the session progresses. The page and its content come straight from your computer and never pass through any server. Links last 1 hour, 24 hours or 7 days, and you can stop sharing at any time, which disables the address immediately.

### Improvements

- **Refresh Today’s Usage at any time** (Mac, iPhone, iPad): A refresh button next to the Today’s Usage title reloads every computer's plan limits and today's usage on the spot. While the iPhone or iPad home screen is open, limits now refresh automatically every 5 minutes; previously they were read only once when the app connected, so the readings went stale if you stayed on the home screen. The "minutes ago" time next to each reading now keeps up as well. Claude Code and Codex report their limits with each reply, so a computer that hasn't been used for a while keeps its last reading.

## 3.49.19 (2026-11-03)

### Bug Fixes

- **SVG images from agents now display correctly** (Mac, iPhone, iPad): SVG images sent by agents (such as the test report overview created when no browser is available on the computer) could not be shown on iPhone and iPad, and appeared without their text on Mac. They are now converted to regular images before they are sent, and similar images sent earlier are converted automatically when you view them.
- **Flow board cards no longer flash black when a session joins** (Mac, iPhone, iPad): When a new session joined and the session column was rearranged, session cards briefly showed as black bars with no text. They now show their content right after the rearrangement, and the board no longer flickers when it opens.

## 3.49.18 (2026-11-02)

### Improvements

- **No more brief "computer offline" during plugin updates** (Mac, iPhone, iPad): When Kiteline installs or updates an agent plugin automatically, or you turn a plugin on or off in Settings → Plugins, the plugins have to be reloaded. Previously, for a few seconds during the reload your phone showed the computer as offline, the session list was emptied, and messages or actions sent in that window failed. Now sessions stay visible and the computer stays online throughout; messages and actions sent in the meantime are carried out as soon as the reload finishes, and actions already in progress are completed first.

## 3.49.17 (2026-11-02)

### New Features

- **Getting Started guide** (Mac): The first time you open Kiteline, a four-step guide appears. Step 1 explains that Kiteline is a companion for coding agents and checks which agents are installed on this computer (Claude Code, Codex, OpenCode and more). If none are found, it explains what to install first and links to the VS Code download; if your agent isn’t listed, you can send us its name and a note so we can prioritize support. Step 2 grants the required permissions and lets you open Kiteline at login. Step 3 shows a QR code for the iPhone app, then a pairing QR code and code, and confirms as soon as your phone is paired. Step 4 explains the virtual screen and lets you turn it on. Reopen it anytime from Kiteline → Getting Started or the main window’s welcome page.
- **The iPhone app explains how to install the desktop app** (iPhone, iPad): The first-launch guide has a new “Install Kiteline on Your Computer” page that explains how the desktop app and the iPhone app work together, what the desktop app does, where to download it, how to install it on Mac, Windows and Linux, and where to find the pairing code. You can copy the download link or send it to your computer with AirDrop, WeChat or Mail. The pairing screen adds “No desktop app yet? See how to install”, where you can also try Demo Mode if you don’t have a computer at hand.
- **Goals (/goal)** (Mac, iPhone, iPad, Apple Watch): Claude Code (2.1.139 or later) and Codex sessions in the terminal can now be given a goal. The agent keeps working toward it across turns, checks at the end of each turn whether it has been met, and stops only once it is confirmed, which suits long tasks you want the agent to push forward on its own while you're away from your computer. Tap Goal below the input box in a conversation to set one; whatever you've already typed in the input box becomes the goal. You can also open it from the session menu, with multi-line and voice input. Once set, the session list shows progress such as Goal · round 3 (also on Apple Watch), and above the input box the conversation shows the goal, the current round, the time spent and the result of the latest check; tap it to see details, clear or replace the goal, and pause or resume Codex goals. Each check result is also marked in the conversation. You're notified when a goal is achieved, can't be achieved or stops along the way (for example after an API error or when a usage limit is reached); while a goal is in progress you no longer get a separate Completed notification at the end of every turn. Goal progress is also shown for Codex desktop app and VS Code extension sessions; goals for those are set in Codex.
- **Cursor support** (Mac, iPhone, iPad): When Cursor is installed on your computer, Kiteline installs the Cursor plugin automatically. You can view Cursor editor and CLI agent chats on your phone (status, full history, diffs and task lists), send messages, allow or reject commands and stop tasks. For idle editor chats, Kiteline brings the Cursor editor window for that project to the front to send, then switches back to the app you were using. Chats in the Agents window or in remote workspaces explain why they can't be controlled. Turn on Show monthly usage under Cursor in Settings → Plugins to see Cursor's usage this month under Today’s Usage.
- **Usage stats now include every agent** (Mac, iPhone, iPad): Tokens, requests and spend in Today’s Usage and on the Usage page used to count Claude Code only. They now also include Codex, OpenCode, DeepSeek Harness, Qwen Code, Proma and Cursor (for Cursor, turn on Show monthly usage under the plugin), and the Usage page adds a By Agent breakdown. Spend comes from each agent's own records; agents and models that don't record spend are marked Tokens only instead of showing $0. The daily spend alert and spend cap now count spend recorded by all agents.

### Improvements

- **Dialogs now share a standard window style** (Mac): All in-app dialogs (Goal, Model & Effort, Session Info, New Task, confirmations, update prompts and more) now have a title bar with the title in it and close and full-screen buttons in the top-left corner. Full screen fills the current display, and clicking again restores the original size. Content scrolls under the title bar instead of overlapping the title. Plugin error notices also gain a close button.
- **Exchanges between sessions no longer notify you** (Mac, iPhone, iPad, Apple Watch): When a session replies to a message from another session (including another session's post in a session group), you no longer get a Completed notification, and images sent during that turn are no longer pushed; the reply is still in the conversation. You are still notified when the session stops on an error or needs your confirmation, and when you also messaged the session during that turn. The screenshot skill and the session group instructions have been updated to match: when replying to another session, a session replies only to the sender and no longer sends you a separate report.
- **Flow board now sits on a grid canvas** (Mac, iPhone, iPad): The flow board background is now a canvas with a two-level grid of small and large squares. Grid lines stay crisp as you zoom, and the small squares fade out as you zoom out. The star decoration in the old background has been removed.

### Bug Fixes

- **Slash command output no longer shows stray tags** (Mac, iPhone, iPad): After running a slash command such as /model in Claude Code, the output shown in the conversation used to include a “<local-command-stdout>” tag. It's now removed.
- **Group chat messages now use the same font as sessions** (Mac, iPhone, iPad): Messages in a session group used the system's default text size and line spacing, so they looked different from messages in a session. Group messages now use the same font, size, line spacing and bubble style as sessions, and follow the font and text size set in Appearance.
- **Kiteline skill commands now run for Codex and other agents on Windows computers reached over Remote-SSH** (Mac): When these agents ran skill commands such as screenshots, to-dos and task progress in PowerShell, the command failed because it was not written in a form PowerShell accepts. The same command now runs as is in PowerShell, Command Prompt and Git Bash.

## 3.49.16 (2026-11-02)

### New Features

- **Flow board** (Mac, iPhone, iPad): A new Flow entry next to World Mode puts every session on one screen: on the left, what sessions read (your requests, project files, memory, web pages, command output); in the middle, each session and its current stage; on the right, what sessions do (explore, edit, run and test, collaborate) and where the results go (changed files, check results, commits and pushes, messages to you and other sessions, plan progress). Every tool call draws a faint line across the columns; when a call happens, a stream of glowing dots flows along it and lights the line up; sessions that are working keep a few dots drifting slowly between calls, while idle sessions stay still. Four live panels at the bottom show call and thinking waveforms, call volume by tool, a model and context overview, and test and build results per session, and every call lights them up. The camera directs itself by default, panning and zooming to a busy card and listing the latest calls that passed through it (what was done, on what, by which session) before returning to the overview; you can drag and zoom, tap a card to show only its links, and tap a session card to open that session. On Mac, click the button next to the globe at the top of the sidebar or press ⇧⌘D; on iPhone and iPad, tap the button next to the globe at the top left of the session list.
- **Usage limits that match each agent's billing** (Mac, iPhone, iPad): Besides the 5-hour and weekly limits of Claude Code and Codex, the Today’s Usage card and the Plan Limits section of the usage page now show your DeepSeek account balance in DeepSeek Harness (including bonus balance), and support monthly and daily limits: each agent shows as many bars as it has periods, ordered 5-hour, today, this week, this month. Requires signing in to a DeepSeek account in DeepSeek Harness; the balance isn't shown when using an API key.
- **Usage limits explained for each plugin** (Mac): Each plugin in Settings → Plugins now has a Usage limits line explaining whether that agent's limits or balance can be shown under Today’s Usage and where they come from; when they can't, it explains why and where to check them. Plugin features that need to read an agent's sign-in credentials (such as checking Cursor's monthly usage) are off by default and turned on separately below the plugin, with an explanation of what is read before you turn them on.
- **Update reminders** (Mac, iPhone, iPad): When a new version is available, an update window now opens automatically, showing the version number, how many versions behind you are, and what's new in each version since yours, and you can download and install it right away. Choose Not Now to be reminded again in 24 hours, or select "Don't remind me about this version" to skip that version; you'll be reminded again when a newer version is released. The window opens without switching to Kiteline, so typing in other apps isn't interrupted. Kiteline on iPhone and iPad also checks the App Store for new versions when you open it, shows what's new, and takes you to the App Store to update.
- **Your phone and computer remind each other about updates** (Mac, iPhone, iPad): When Kiteline on a paired iPhone or iPad is older than the version on the App Store, Kiteline on your computer tells you which devices need updating. When Kiteline on the computer your iPhone or iPad is connected to has a new version, the update reminder on your phone lists what's new too, and you can have your computer download and install it in the background, then restart Kiteline on your computer from your phone to finish (requires this version or later of Kiteline on your computer, downloaded from the website).

### Bug Fixes

- **Sessions idle since before the update now close on time** (Mac, iPhone, iPad, Windows, Linux): Sessions that were already open when you updated to 3.49.15 had their 24-hour countdown restarted from the update, so they were not closed on time. Kiteline now uses the last-viewed times recorded on each of your devices, and sessions not viewed for more than 24 hours before the update are closed at the next check (when VS Code needs to be switched, Kiteline still waits until the computer has been idle for 10 minutes).
- **A dismissed "Update Kiteline" notice no longer reappears** (iPhone, iPad): The notice shown on the home screen when a plugin on your computer requires a newer version of Kiteline reappeared after the app fetched its service configuration. This has been fixed.
- **Notices and badges in the session list no longer overlap** (iPhone, iPad): When a status filter matched no sessions, the "No … sessions" notice covered Today’s Usage, the to-do reminder and the filter bar above it; it now appears below the filter bar. When the To-dos tile on the home screen shows both your to-do count and items that need your attention, the two numbers no longer sit on top of each other: items that need your attention (red) appear at the icon's top-right corner and the to-do count moves to the top-left.

## 3.49.15 (2026-11-02)

### New Features

- **Idle sessions close automatically** (Mac, iPhone, iPad, Windows, Linux): sessions whose details have not been opened in Kiteline for 24 hours now have their tab on the computer closed automatically and move to History, including marked and pinned sessions, so sessions you no longer use don't tie up the computer or crowd the tab bar. Opening a session's details on any device, or sending a message from them, counts as opening it; messages from other sessions and replies the session makes in the background do not. A running session is closed after its current turn ends, and when VS Code has to be switched, Kiteline waits until the computer has been idle for 10 minutes so it doesn't interrupt you. To continue, open the session in History and send a message; it returns to the session list. This is on by default and can be turned off in Settings → General → Sessions on the Mac.

### Improvements

- **Reminders when an agent forgets to report its progress** (Mac, iPhone, iPad, Apple Watch): with Install Task Stage Skill turned on, Kiteline also installs a small plugin for Claude Code. When Kiteline sees that the agent has moved on to the next step (for example, it has started testing, or has said what it will do next) without reporting it, it reminds the agent to report after its next action; when the agent has been changing code for a while without planning its steps, it reminds it to plan them. Reminders are shown only to the agent, not in the conversation, and take effect in newly started Claude Code sessions.
- **Group chats join the session list and open in tabs** (Mac, iPhone, iPad): Group chats no longer sit above the session list. They now form their own group in the list, below the filters and ahead of the sessions. When you filter by device, project or status, or search, only groups with members in the results are shown, and search also matches group names. On Mac and iPad, a group chat opens just like a session: as a tab on the right that can sit side by side with sessions, be dragged to any side to split, or be opened from the context menu (long-press on iPad) with "Open in Split on Right" or "Open in Split Below". The tab bar lets you mark the group and show its members; other actions are in the "⋯" menu. Drop a session in the middle of a group chat to add it to the group, or near an edge to split as usual. A new tab's "Choose a session" list also includes groups that aren't open yet. When a group is disbanded, its tab closes automatically.
- **Group chat input matches sessions** (Mac, iPhone, iPad): The group chat now uses the same input bar as a session. You can send images (from Photos, the camera, a pasted screenshot or by dragging them in) and files, use quick replies, and on iPhone hold to talk (your speech is transcribed and posted to the group). The row below the input no longer shows permission mode, model and context; it shows "To all members" instead, where you can pick specific members to send to. Images and files sent in a group are copied to the computer each member runs on and delivered with the message; for members whose sessions are closed, they're delivered when the session is resumed.
- **Faster opening and closing of split panes** (Mac): When you add or close a column, the sessions in the other columns are no longer reloaded, so there is much less lag. Opening and closing split panes and moving tabs to another pane no longer play a transition animation; the columns snap into place, just like in VS Code.

### Bug fixes

- **Task progress keeps up with the actual work** (Mac, iPhone, iPad, Apple Watch): Previously, when an agent had planned its own steps and reported one of them, then started editing code, running tests or sending screenshots without reporting the next step, the session list and task progress stayed on the earlier step. Now, when these actions clearly match the next planned step (for example, moving from diagnosing to fixing), Kiteline moves on to that step and marks it as detected automatically. Steps still only move forward and never skip a step that can't be recognized. When an agent hands work such as testing to a subagent running in the background, the current step is now also recognized from the subagent's task: for example, it shows Testing while a subagent runs browser tests, instead of staying on Developing.
- **Session list freezes or quits when scrolling with the trackpad** (Mac): Scrolling the session list with two fingers on the trackpad could freeze the interface (with a spinning cursor) or make Kiteline quit unexpectedly; dragging the scroll bar with the mouse was not affected. The Mark and Close buttons that appear when you hover over a session no longer change the size of the session card, so scrolling stays smooth.

## 3.49.14 (2026-11-01)

### Improvements

- **Task progress moved above the input box** (Mac, iPhone, iPad): while a session is working, a single line above the input box shows the current step, what is being done and how long it has taken. Tap it or swipe up to see all steps: completed steps are checked and struck through, and the current step is highlighted in the theme color. When a task is split into parts (for example, several platforms), each part has its own row, with the steps of the current part listed under it. The task progress card that appeared at the top of the conversation, and the step labels in the title bar and the “Working” line, are no longer shown; step labels in the session list are unchanged.
- **Group chats: New Group button, marking and muting** (Mac, iPhone, iPad): a New Group button now sits to the right of the Sessions heading in the session list; tap it and pick the sessions to invite (at least two) to create a group. With many sessions, filter them by device or project at the top of the panel; the create button stays pinned at the bottom. Groups can now be marked, muted or disbanded just like sessions: on iPhone and iPad, swipe right on a group to mark it, or swipe left to mute or disband it; on the Mac, right-click a group or use the menu in the top-right corner of the group chat. Marked groups stay at the top with a star after the name. When an agent posts in a group you get a notification (at most one every two minutes per group), except for muted groups; tap the notification to open the group chat.
- **Explanation when connecting over a VPN** (iPhone, iPad): the free version works when your phone is on the same Wi-Fi as your computer. Connecting back to your computer from another network through a VPN such as Tailscale counts as remote access and requires a subscription. In that case, a notice at the top of the session list explains why; tap it to see the subscription.

### Bug fixes

- **Messages shown as sent although they were not submitted** (Mac): if another app took the foreground on the computer while a message from the phone or Kiteline was being delivered to a session in VS Code, the text could miss the input box, or the Return key could miss it, and the message was still shown as sent. Kiteline now checks the input box after pasting and after pressing Return: if the text is not there, it brings VS Code back to the front and pastes again; if it was not submitted, it presses Return once more. If it still fails, Kiteline says so and names the app that was in front.
- **Clearer “not delivered” notice** (Mac, iPhone, iPad): when a sent message never shows up in the conversation, the notice now reads “Not in the conversation yet. Please check on the computer.”

## 3.49.13 (2026-11-01)

### New Features

- **Group chats: sessions talk to each other across devices and projects** (Mac, iPhone, iPad, Windows, Linux): Put several sessions in a group so they can coordinate directly, for example when one session needs to migrate a server that another session is still using. Sessions can be on different computers and belong to different projects. Drag one session onto another in the session list, or choose Start Group Chat from a session's menu, pick the sessions to include and, optionally, describe what they should work on together; that description is sent to all members as the first group message. Each member receives a group briefing (who the members are, which computer and project each one is in, and how to post), and Kiteline relays their messages from then on, with reply instructions attached to every group message. An agent names the group based on the work, and you can rename it at any time.
- **Group chat page**: Active groups appear at the top of the session list. Open one to see every message exchanged and whether each one was delivered, and post in the group yourself, to all members or only to selected ones, by typing or by voice. Tap the Members button in the top-right corner to slide in the member list from the right, showing each session's computer, project and current status; tap Add Members to bring in more sessions. On a computer, simply drag a session from the sidebar into the group chat to add it. Messages to a session that is waiting for your approval are delivered once you respond. If agents exchange a long run of messages, relaying pauses automatically until you choose to continue.
- **Past groups**: When all member sessions are closed, the group becomes a past group. Posting in a past group resumes those sessions in their original projects and catches them up on the group messages they missed, so they can keep working together. In a session's own conversation, group messages appear as cards; tap one to open the group chat.

### Bug Fixes

- **Task progress no longer jumps back and forth** (Mac, iPhone, iPad, Apple Watch): Previously, when an agent alternated between editing code, compile checks and running tests, the step in the session list could flip between Developing and Testing, and when an agent planned its own steps but didn't report them one by one, the step shown could be the wrong one. Detected steps now only move forward, and tasks whose steps were planned by the agent show exactly the step the agent reported; if the agent hasn't reported its progress for a while, Kiteline reminds it to.

## 3.49.12 (2026-11-01)

### Bug Fixes

- **The virtual display no longer keeps appearing and disappearing after you turn off your display** (Mac): With the virtual display on, turning off or unplugging your display when no other display was connected made the virtual display get created and removed every second, moving windows back and forth. The virtual display now stays removed until a display is reconnected and stays connected for a few seconds; if the display keeps dropping out, Kiteline waits longer each time. Kiteline also no longer keeps moving windows when the virtual display is the only screen.

## 3.49.11 (2026-11-01)

### New Features

- **See each session's progress in the session list** (Mac, iPhone, iPad, Apple Watch): Sessions that are working now show their current step in the accent color before the status, such as "1/4 Researching", "2/4 Developing", "3/4 Testing" or "4/4 Reporting", so when several sessions are open you can see at a glance which ones are working and how far along each one is. Steps are detected from what the agent does, and nothing is shown when it is only answering a question or looking things up: reading code and looking things up is Researching, editing files is Developing, running tests and checking screenshots is Testing, sending screenshots and reports is Reporting, and committing, pushing, installing or deploying shows as Releasing. The new Task Stage skill (Settings → Agent Integration, on by default) has agents plan steps that fit the task at hand (for example, "Reproduce, Locate, Fix, Verify, Report" for a bug) and report each step as they enter it, optionally with a short note on what they're doing; progress carries on when you reply "continue". Tasks done across several platforms or modules go through the steps once per part and show as "●●○ iPhone · 2/4 Developing" in the list, with the dots showing which parts are done. If you and the agent agree on a fixed process, later tasks in the same project keep using it.
- **Task progress in the conversation** (Mac, iPhone, iPad): When you open a working session or it moves on to the next step, a Task Progress card appears at the top of the conversation, listing the steps, the time spent on each and the agent's note (for tasks split into parts, a table shows the progress of each part). It hides after 8 seconds; tap the card to keep it open. Tap the step badge in the "working" row to see it again.

- **See your plan usage limits in the session list** (Mac, iPhone, iPad, Windows, Linux): The "Today’s Usage" card in the session list now spans the full width. The number next to its title is the total tokens used today across all your computers (input, output and cache). Below, each computer shows its Claude Code and Codex 5-hour and weekly limits, with the computer name on the left and the agent name and reading time on the right; the two limits appear side by side with the percentage used and the reset time, and turn red at 80%. Tap the card for spending, output and other details; the new Plan Limits section at the top of the Usage page also lists each computer's limits. Claude Code limits are available only when you sign in with a Claude subscription: Kiteline adds a plugin to Claude Code on your computer that records nothing but the limits, and they appear after a reply in a newly started session. Sessions opened before the plugin was added don't record limits. Codex limits are read from its local records. The "Today" and "Today’s Usage" cards have swapped places: on Mac, "Today" now sits next to "Past Sessions" in the sidebar; on iPhone and iPad, it has moved into the shortcut tiles below.

- **Terminals inside sessions** (Mac, iPhone, iPad): A terminal button now appears below the input box. Tap it and a terminal slides up from the bottom, inside the session; the number on the button shows how many terminals the session has open. The terminal runs on the computer where the session runs: for projects opened over Remote-SSH, that is the server itself, starting in the project folder with the same environment as the terminal in VS Code. You can open several terminals and switch between them, with full color, Chinese input, and keys such as Ctrl+C. On iPhone, a row above the keyboard provides Esc, Ctrl, Tab, and arrow keys, and you can drag the top edge of the terminal to resize it. Programs keep running after you hide the terminal or leave the session, and the screen picks up where it left off when you reopen it. On Mac, press ⌃` to toggle the terminal. Opening and closing terminals is recorded in the activity log; what you type is not.

### Improvements

- **Filter projects by device and project in New Task** (Mac, iPhone, iPad): When you choose a project, Device and Project filters now appear above the list, each showing how many projects it contains; tap a selected filter again to show all. The filters appear only when you have more than one device or project. New Task starts with the device and project currently selected in the session list, and if only one project matches, it is selected automatically. Changing the filters in New Task doesn't affect the session list.
- **The virtual display no longer takes over anything of yours** (Mac): The virtual display is used only for VS Code. If macOS moves it, makes it the main display, or adds it to a mirror set, Kiteline puts it back and brings the VS Code windows along, leaving your display arrangement and mirroring unchanged. When you close your laptop lid or turn off your display and no other display is connected, the virtual display is removed temporarily so the menu bar, Dock and windows aren't moved to a screen you can't see; it returns automatically once a display is connected. Windows from menu bar apps that open on the virtual display are moved back to your main display.
- **The code window is now a standard window** (Mac): The code IDE now has close and zoom buttons in the top-left corner. Double-click the title bar to fill the screen, and double-click again to restore it. The title bar is a single color, and the project name sits right after the window buttons. The top-right corner shows the current branch and how many commits it is ahead of or behind the remote (also on iPad); click it to open Branches & Sessions. Pressing Esc no longer closes the code window, so in the editor Esc only dismisses find and autocomplete. At its narrowest, the window keeps the wide layout, so your open tabs are never lost.

### Bug Fixes

- **Messages now reach sessions without a generated title** (Mac, iPhone, iPad): Claude Code occasionally fails to generate a title for a session; VS Code then names the tab after the first message you sent. Kiteline previously treated such sessions as if no message had been sent yet, showed only the project folder name, and could not deliver messages or confirmations from your phone. The session list now shows that message, and Kiteline correctly identifies the tab before sending. Sessions renamed in VS Code also show their new name.
- **You can drag the code window by its title bar** (Mac): Previously, the backgrounds of the code IDE sidebar and editor extended under the title bar, so dragging the title bar did not move the window and the title bar was two different colors. This is fixed. Other panels can also be dragged from any empty spot in the title bar.
- **Closing the code window now asks about unsaved files** (Mac): If any files are unsaved when you close the code window, Kiteline asks whether to Save All and Close, Close Without Saving, or cancel, so you don't lose your changes.

## 3.49.10 (2026-10-31)

### New Features

- **Code IDE** (Mac, iPhone, iPad): "Files" in a session is now a full code editor. On Mac and iPad it uses the same layout as VS Code: Explorer, Source Control, and Branches & Sessions on the left, with tabbed editors and a status bar on the right; on iPhone it is organized into Files, Changes, History, and Branches. The editor uses VS Code's color themes and offers syntax highlighting for more than 50 languages, code folding, find and replace, multiple cursors, bracket matching, autocompletion, and a minimap, with colored bars next to the line numbers marking uncommitted changes. Press ⌘S to save. Before saving, Kiteline checks whether the file on the computer has changed (for example, if Claude just edited it) so neither change overwrites the other, and the file's original line endings and encoding are preserved. On iPhone, files open read-only by default and the keyboard appears only after you tap Edit; a row above the keyboard provides Tab, brackets, quotes and other common symbols, plus undo and find.
- **File management** (Mac, iPhone, iPad): In the Explorer you can create files and folders, rename, copy, cut and paste, duplicate, drag to move, upload files or photos, copy paths, and reference files in the conversation. Deleted files are moved to the computer's Trash (the Recycle Bin on Windows), so they can be restored at any time.
- **Git source control** (Mac, iPhone, iPad): Merge conflicts, staged changes and unstaged changes are listed separately, and you can stage, unstage or discard whole files or individual hunks. Changes are shown side by side or inline with syntax highlighting. Enter a message to commit, commit and push, or amend the last commit, or have Claude write the message and commit. Pull (merge or rebase), push, fetch, force push (--force-with-lease), stash and pop are supported. When a merge or rebase runs into conflicts, choose the current branch's or the incoming version, then continue or abort. Long operations such as push and pull run in the background on the computer and are not affected if your phone's connection drops.
- **Commit history and branches** (Mac, iPhone, iPad): The commit graph draws each branch in its own color to show where branches diverge and merge, and labels branches, tags and remote branches. You can search commits, view commit details and the changes to each file, or view a single file's history. Create, switch, rename, delete, merge and rebase branches, check out remote branches, create tags, cherry-pick or revert commits, or reset the current branch to a chosen commit.
- **See which branch each session is on** (Mac, iPhone, iPad): Branches & Sessions lists the sessions running on each branch, grouped by worktree, along with their status, for example "3 sessions on main, 1 session in the feature/coupon worktree." Branch labels in the commit graph and the branch list also show session counts, and project details and session info show each session's branch. Before you switch branches while sessions are running in the current folder, Kiteline warns you and suggests checking the branch out in a new worktree so the sessions can work in parallel.
- **Send files to Claude from other apps** (iPhone, iPad): In WeChat, WeCom, Files, Mail and other apps, choose "Open in" and pick Kiteline. Images, PDFs, Excel and Word files appear in the "Send to Session" panel, where you can add a note (or hold to dictate) and send them to an existing session, or pick a project to start a new one. Images appear directly in the conversation; other files are transferred to the computer running the session, and Claude receives their paths and reads them. A new "File" option under "+" in the conversation lets you send files from the Files app.
- **Open files Claude creates** (iPhone, iPad, Mac): File paths on your computer that Claude mentions in its replies, such as an Excel sheet or a PDF report saved to the desktop, can now be opened directly. On iPhone and iPad, tap the path and Kiteline fetches the file from your computer and opens it in the system preview, where the button in the top-right corner forwards it to WeChat or another app or saves it to Files; on Mac, click the path to open the file in its default app. Touch and hold a message and choose "Forward File" to forward it directly. Files you send appear as file cards in the conversation; tap one to open it again. Files whose names suggest keys or passwords (such as .env files or private keys) are not sent to your phone unless you confirm.
- **Forward images in conversations** (iPhone, iPad): Touch and hold a message with images and choose "Forward" to send the original images to WeChat or another app.
- **Filter sessions by device and project** (Mac, iPhone, iPad): Past Sessions and the session list now have Device and Project filters below the status filters: tap one to show only that computer's or project's sessions, and tap it again to show all. Each shows its session count, and the filters appear only when you have more than one device or project. When you choose a project, Past Sessions lists all of that project's sessions (not only the most recent ones), sorted by date. With All Projects selected, you can still group by project, source and more.

### Improvements

- **Every feature is free on the same Wi-Fi** (iPhone, iPad, Apple Watch): When your phone and computer are on the same Wi-Fi, replying, voice, images, approvals, answering questions, creating tasks and every other feature are free. A Kiteline Pro subscription is now only needed for Remote Access, which connects to your computer peer-to-peer or through relay servers when you are not on the same Wi-Fi; the relay servers incur ongoing server and bandwidth costs, which subscriptions help cover. Monthly and annual prices have been cut in half.
- **Search past sessions by project name and title** (Mac, iPhone, iPad): Besides conversation text, sessions whose project name or title contains your search term are now listed, with a note showing whether the project name or the title matched. On Mac, results appear as soon as you pause typing, without pressing Return. Searches are about three times faster, and searches that previously timed out with partial results now return everything.

### Bug Fixes

- **Messages sent from your phone no longer end up in VS Code's terminal** (Mac): Previously, if VS Code's keyboard focus was in the terminal, an editor or another panel, a message sent from your phone could be pasted into the terminal, and VS Code would ask "Are you sure you want to paste multiple lines of text into the terminal?". Kiteline now checks the focus before sending a message or choosing a confirmation option, and moves the cursor into the session's input box first when needed. If it cannot, the message is not sent and your phone shows the reason. If the terminal prompt has already appeared for this reason, Kiteline clicks "Cancel" automatically and no longer pushes it to your phone. Prompts that appear when you paste into the terminal yourself are not affected.
- **Thin borders display fully on non-Retina displays** (Mac): On non-Retina (1x) displays, the top edge of the thin border around the message box, confirmation cards and similar elements was missing. This has been fixed.
- **The Dock no longer disappears when the virtual screen is on** (Mac): Previously, when the Dock was on the right side of the screen, turning on the virtual screen could move the Dock onto the virtual screen, out of sight. The virtual screen now stays clear of the Dock and adjusts automatically when the Dock moves.

### Security

- **Claude.ai Artifact links are no longer opened** (Mac): Opening claude.ai from a network or IP address different from the one you usually use Claude on may get your account flagged. After Claude publishes an Artifact, VS Code opens a preview automatically and asks "Do you want Code to open the external website?". Kiteline now clicks "Cancel" for every Artifact link, whether it is an automatic preview or a link clicked in a session, and no longer pushes these prompts to your phone. This also fixes messages sent from your phone not being delivered while the prompt was open. Sign-in and other links are not affected.
- **Claude.ai links in messages are no longer clickable** (Mac, iPhone, iPad, Apple Watch): Claude.ai links in messages, favorites, plans and other content are now shown as plain text, so they cannot be opened by accident on your phone or another network.

## 3.49.9 (2026-10-27)

### New Features

- **World Mode** (Mac, iPhone, iPad): Click the pixel globe at the top of the sidebar or press ⇧⌘E (on iPhone and iPad, tap the pixel globe at the top left of the session list), and the right side becomes a pixel-art company campus that shows every session at a glance. Each coding agent is a server room whose rack lights blink faster the more of its sessions are working; each computer is a satellite circling the campus, labeled with its processor and memory usage; and each session is a blocky character at a desk, seated by project, with its latest action or message shown above its head. When a session is working, its character types and code scrolls on the screen; when it needs your approval, it turns around and raises a hand; when it hits an error, it holds its head and the screen turns red; when it is idle, it naps on the desk. When an agent replies, a beam of light travels from its server room through the satellite to the right computer; when sessions message each other, the characters get up, walk over and talk face to face, and the conversation is read aloud at 2× speed. Each project's wall holds sticky notes for its to-dos: an agent pins a note to the wall when it records a to-do and takes it back to its desk when it starts on it. A meter on the company wall shows today's tokens and cost, and slogans hang on the surrounding walls. The chat box at the bottom left logs every reply, conversation and tool call; click a character or a name in the chat box to chat privately with that session by typing, pasting a screenshot or dictating. Click a character's screen to view and reply to that session on the right, and click a satellite for device details. Drag the floor to move, right-drag to rotate, scroll to zoom, or use W, A, S, D to move and Q, E to turn; click the door at the top left to leave, and use the button next to it to hide the session list.

### Bug Fixes

- Fixed an issue where Kiteline could quit unexpectedly when you pressed ⌘Z to undo after closing the New Task panel, or switching or closing a session.
- Fixed an issue where closing a session in VS Code could occasionally also close another recently used session.

### Improvements

- **Full home cards in the iPad session list** (iPad): The session list on iPad now shows Today, Today's Usage, and the To-Dos, Favorites, Projects and History shortcuts above your sessions, just like iPhone, instead of a single summary line.
- **Faster update notices** (Mac): Kiteline now checks for updates every hour instead of every 6 hours, so a new release appears at the bottom of the sidebar within an hour.
- **Agent to-dos are closed promptly** (Mac, iPhone): Coding agents now mark a to-do as done as soon as they finish it, and close items that are no longer needed with a note explaining why. When an agent sends a screenshot or reports progress while it still has open to-dos, it is reminded to close them, so finished items no longer linger in the list. A session that takes over a to-do recorded by another session, or on another computer, can close it when done; when an agent records a to-do that already exists, it continues with the existing one instead of adding a duplicate. To-dos whose session has ended are labeled "Session Ended" and listed last; you can mark them as done directly (swipe right on iPhone, right-click on Mac) or use "Create Session" to continue the work.
- **Group agent to-dos by project or agent** (Mac, iPhone): Agent To-Dos now has a View Options menu, just like the session list. Group by source, project or agent; sort by status, recently updated, date added or name; and, if you use several computers, show only one of them. Until you choose otherwise, grouping follows the session list. To-dos stay with their original project and agent even after their session ends.

## 3.49.8 (2026-10-27)

### New Features

- **Web Test Reports** (Mac, iPhone): After finishing or fixing a web feature, Claude uses Playwright to walk through it in a real browser the way a user would, takes a screenshot at every step, and sends a test report designed for reading on your phone: an overview showing whether the tests passed and why any failed, one screenshot sequence per test, and a short text summary. You can also simply ask Claude to test or verify something. Kiteline installs this skill automatically for the coding agents on this computer and on computers connected through Remote-SSH; you can turn it off under Agent Integration in Settings. If a project does not use Playwright, it is set up in Kiteline's own folder without changing your project.
- **To-Dos and Key Info** (Mac, iPhone): To-dos are now split into My To-Dos and Agent To-Dos, shown separately. For things only you can do, such as registering an account or getting an AppID or a key, the coding agent reminds you through Kiteline: choose Handle Now, or Add to To-Dos to deal with it later. When you are done, tap Back to Session to return to the original session and tell the agent. Work the agent will do later itself, such as work that could not be finished this time or work waiting on a condition, goes into Agent To-Dos and is handled by the agent; you can see which session is handling it and how far it has got. Each agent to-do remembers which session it came from: tap Create Session to open a new session with the task and the original project already filled in, and start it once you have confirmed. When an agent gives you information you will need later, such as accounts, passwords, keys or server addresses, it also sends a separate Key Info card: each item can be copied on its own, passwords are hidden until you tap to reveal them, and tap Save to add the card to Favorites.
- **Mark Sessions** (Mac, iPhone, iPad): When you are running many tasks at once, mark the sessions you need to keep an eye on, such as ones paused while waiting. Marked sessions show a star in your theme color and appear at the top of every session list, regardless of grouping. A new Marked filter at the top of the session list shows only marked sessions. To mark a session, swipe right on it or touch and hold it in the session list (on Mac, right-click it or click the star that appears when you point at it), or tap the star at the top right of the session (on Mac, in the tab bar); tap again to unmark. Marks are removed automatically when a session is closed or ends.
- **Landscape on iPhone** (iPhone): A new rotate button at the top right of the home screen turns the interface to landscape; tap it again to return to portrait. If you turn your phone and the interface does not follow, a slowly pulsing rotate button appears in the corner; tap it to switch. In landscape the layout matches iPad: the session fills the screen, the session list slides in from the left as a rounded glass panel that can be hidden at any time, To-Dos, Favorites, Projects and History are available at the top of the list, and Settings and New Task open inside the panel without covering the session you are viewing. You can split the view side by side into up to three columns. To save space, the navigation bar is hidden and Mark, Read Aloud and the session menu move to each pane’s title bar; permission mode, model and context move to either side of the Home indicator; the + panel fits in one row; confirmation and choice cards use smaller text and buttons; and bars you do not need while typing are hidden so the input field stays visible. The space above and below the notch or Dynamic Island shows today’s usage and the number of sessions, sessions waiting for confirmation and errors. Content stays clear of the notch, Dynamic Island and Home indicator.
- **Alerts When VS Code Shows a Dialog** (Mac, iPhone): When VS Code shows a dialog that needs your attention — for example, Remote-SSH cannot connect, “Cannot reconnect” after a disconnect, “Workspace does not exist” because a remote folder is temporarily unavailable, or a save prompt before closing — Kiteline sends the dialog text to your phone and shows it at the top of the session list until the dialog closes. Nothing is sent while you are using the computer. For connection-related dialogs, tap Try Reconnecting on your phone: Kiteline presses Retry or Reload Window in the dialog for you, or closes the dialog and reloads the window when there is no such button.
- **Alerts When a Connected Computer Goes Offline** (Mac, iPhone): If Kiteline loses its connection to a computer connected over SSH for more than a minute (its sessions temporarily disappear from the list), you get a notification and the reason is shown at the top of the session list. Tap Try Reconnecting to reconnect right away; you are notified again once it is back. For both kinds of alerts, you can also press and hold the Lock Screen notification and choose Try Reconnecting.
- **Agent Details and Custom Avatars** (Mac, iPhone, iPad): In a session, tap the agent's avatar or the agent logo before the title (on Mac, click the avatar, or choose Agent Details from the session menu or the sidebar's context menu) to open Agent Details. The avatar and nickname are at the top and can be changed right there. Below them you can see the agent's type and version, whether it runs in the VS Code extension or a terminal, the Kiteline plugin version and the actions available remotely, the session's model and working directory, and the IP address, operating system, processor and current usage of the device it runs on. Choose an avatar from the presets (the agent's logo, the kite, the nickname's initial or an emoji, on nine background colors) or upload an image. Once changed, the agent's avatar in the conversation, the session title bar and the session list update accordingly, and the nickname appears below the title. Use it for the current session only, or for every session of that agent on this computer, including new ones. Avatars and nicknames are stored on the computer and stay in sync on every iPhone, iPad and computer connected to it.
- **Device Details** (Mac, iPhone, iPad): Tap a computer under Connection in iPhone Settings, or tap the processor and memory usage next to a computer's name in the session list (on Mac, click ⓘ next to a computer in Settings > Sources, or click the usage next to a computer's name in a sidebar group) to see its details: host name and the IP address of each network interface; operating system version, architecture, user and uptime; processor model, core count, memory, disk and live usage; which coding agents are installed and their versions; and the Kiteline component version and number of sessions. Computers connected through Remote-SSH are included.

### Improvements

- **Home Screen and Sidebar Layout** (iPhone, Mac): On iPhone, Today and Today’s Usage now share a row, and To-Dos, Favorites, Projects and History appear as four square tiles in one row, aligned with the cards above. On Mac, To-Dos, Projects and Favorites share one row in the sidebar for a more compact layout. The counts on To-Dos and Projects appear as accent-colored badges, and To-Dos counts only your own to-dos; new items an agent asks you to handle appear as a red badge.
- **Skills for More Coding Agents** (Mac): The screenshot, web test report, and to-do and key info skills are now installed for Claude Code, Codex, OpenCode, DeepSeek Harness and other coding agents on this computer and on remote computers, and Kiteline recognizes which session used a skill. Skill content can be updated online without updating Kiteline.
- **Message Rope in Split View** (Mac, iPad, iPhone in landscape): When two sessions are open side by side, both copies of a letter, the sender's and the receiver's, are connected by a rope that hangs naturally. When the other letter scrolls out of view, the rope attaches to the top or bottom edge of its column to show whether it is above or below. As each column scrolls, the rope stretches and sways; you can drag the rope and it springs back when released. On iPhone and iPad, the rope hangs in the direction the device is tilted. The rope stays faint so it does not get in the way, and becomes clear when you point at either letter or at the rope. You can turn it off under Messages Between Sessions in Settings.
- **Images Read by Claude Shown Inline** (iPhone, Mac): When Claude reads an image or takes a screenshot, the image now appears as a thumbnail right below that step, so you no longer need to open the step to see it. Open it to swipe through every image in that group of steps.
- **Swipe Between Images** (Mac): When viewing an image, swipe left or right with two fingers on the trackpad, or drag the image sideways, to go to the previous or next image. Zoomed-in images still pan as before.
- **Smoother Multi-Column Split View** (Mac): With several session columns open, the interface no longer refreshes as a whole every time a computer reports a status update, noticeably reducing CPU usage. Adding a column or switching between columns no longer causes long freezes, and the working timer at the bottom of a busy session no longer forces the whole column of messages to be laid out again every second.
- **Lower Resource Usage** (Mac): The menu bar icon animation is no longer redrawn frame by frame. When the system is low on memory, the idle on-device speech recognition model is released right away (about 1–2 GB) instead of after 30 minutes. The virtual display now refreshes less often, reducing the system's compositing load without affecting message delivery.
- **One-Click Copy for Code** (Mac, iPhone, iPad): Code blocks, commands, tool input and output, and expanded thinking now have a copy button in the top-right corner (it appears on hover on Mac and is always shown on iPhone and iPad). Click it to copy the whole block; the button briefly shows a checkmark. On Mac you can also select part of the expanded thinking text and copy it.
- **Drag Handles on Split Dividers** (Mac, iPad): When the pointer rests on the divider between two columns (or two stacked panes), a small round handle with arrows appears at the pointer to show that you can drag left and right (or up and down) to resize. The handle follows the pointer and is highlighted while dragging. On iPad, the handle always sits in the middle of the divider. Double-click the divider to even out the sizes again.
- **Leaner Live Sync** (Mac, iPhone, iPad): When the computer syncs the session list to your phone, it now sends only what changed instead of the full list every time, cutting live-connection traffic by about 80% and saving data and battery on cellular and remote access. Takes effect once both the computer and the phone are updated.
- **Sessions Open Elsewhere Are Taken Over Automatically** (Mac): When a session is still open in a terminal or another window, or a VS Code window has just reloaded, Claude Code reports that the session is still open somewhere else and disables the input box. When you send a message from your phone, start a new task or resume a session, Kiteline now chooses Open here anyway and then sends your message.

### Bug Fixes

- **Tab Dragging Works Like VS Code** (Mac, iPad): A dragged tab now follows the pointer. Over a tab bar, an indicator shows where it will be inserted, so you can reorder tabs or move them to another split. Over a split's conversation area, highlighting the whole area moves the tab into that split, and highlighting one half splits off a new pane on that side. Press Esc to cancel a drag. On iPad, drag the title bar at the top of a split the same way; dropping it in the middle of the other split swaps the two. Fixes dragging a tab moving the whole window when the tab bar sits at the top of the window, and drops on another split having no effect.
- **Images Read in DeepSeek Harness Can Be Viewed** (iPhone, Mac): Fixed an issue where opening a step that read an image in a DeepSeek Harness session showed a file description instead of the image. Also fixed images you send in DeepSeek Harness not loading on your phone.

### Removed

- **To-Dos No Longer Guessed from Replies** (Mac, iPhone): Kiteline no longer guesses "things you need to do" from Claude's replies and asks whether to add them to your to-dos. Coding agents now add to-dos on their own when they are actually needed, so things that are not to-dos are no longer reported as to-dos.

## 3.49.7 (2026-10-25)

### New Features

- **Close Sessions** (iPhone, Mac): Each session card in the session list now has a close button in its top-right corner (on Mac it appears when you hover over the card), the session menu includes Close Session, and on iPhone you can also swipe left on a session to close it. Closing a session also closes its tab in VS Code (terminal sessions are sent /exit), so Claude ends the session and frees up resources on your computer. Closed sessions can be resumed from History. Codex, OpenCode, DeepSeek Harness and Qwen Code sessions can be closed as well: OpenCode and Qwen Code quit their terminal interface, while Codex (terminal) and DeepSeek Harness sessions are archived there, so you can find them again in each app.

### Bug Fixes

- Fixed an issue where the iPhone app quit unexpectedly when opened by tapping a push notification.
- Fixed an issue where, after turning on the virtual display, Kiteline's own windows were sometimes moved onto it as well, leaving only the menu bar icon and making the main window impossible to open. Now only VS Code windows stay on the virtual display, and windows from other apps that end up there are moved back automatically.
- Fixed an issue where the session tab bar was occasionally covered by a blur, making tabs and buttons hard to see.

## 3.49.6 (2026-10-25)

### Improvements

- **Less Unnecessary Redrawing** (Mac): Conversation content is now redrawn only when a display actually changes, reducing CPU usage.

### Bug Fixes

- Fixed an issue where toolbar buttons in pop-up windows opened from a conversation, such as the image viewer, sat right against the edges of their button backgrounds. When the window is narrow, buttons that don't fit move into the » menu on the right.

## 3.49.5 (2026-10-25)

### Improvements

- **Undelivered Messages Are Flagged** (iPhone, Mac): If a message you send doesn't reach Claude (for example, because it's still in the VS Code input), it's now marked as not delivered instead of disappearing silently.

### Bug Fixes

- Fixed an issue where text in Mac conversations appeared upside down after a display was turned off and on again, until the window was minimized and restored.
- Fixed an issue where keys typed while Kiteline was delivering a message could land in the VS Code input, leaving the message unsubmitted and merged with the next one. Anything you type during delivery is now passed back to where you were typing once delivery finishes.

### Security

- Fixed an issue where sending a message while Claude was waiting for your confirmation (allow or deny, or a choice of options) would press Return on the default option in the confirmation. Kiteline now asks you to choose in the confirmation card first, and the message is not sent.

## 3.49.4 (2026-10-24)

### New Features

- **Open Source Licenses** (iPhone, Mac): Settings > About now includes Open Source Licenses, which lists the open-source software used by Kiteline along with the full text of each license. You can search by name.

### Improvements

- **DeepSeek Harness Now Turned On Manually** (Mac): DeepSeek Harness doesn't offer an interface for third-party apps, so Kiteline has to read the connection key it stores on your computer in order to connect. So that you can make an informed choice, this plugin is now off by default, including if you were already using it. To keep using it, open Settings > Plugins, expand How It Connects to review the details, and turn it on. Other plugins are not affected.

## 3.49.3 (2026-10-24)

### Bug Fixes

- Fixed an issue where some messages in the English interface (plugin installation and syncing, remote sessions, new tasks, and messages between sessions) were still shown in Chinese.

## 3.49.2 (2026-10-24)

### Bug Fixes

- Fixed an issue on Mac where buttons such as Done and Cancel in pop-up windows were cut off, or their text extended past the button, when using a larger text size or the rounded font. Buttons on the right side of the image viewer are no longer cut off by the window edge.

## 3.49.1 (2026-10-24)

### New Features

- **Favorites** (iPhone, Mac): Touch and hold (iPhone) or right-click (Mac) a message in a conversation and choose Add to Favorites to save its text and images. Favorites are stored on your computer and are kept even after the session ends or its history is cleared; favorites you add on your phone appear on your computer right away, and vice versa. The Mac sidebar and the iPhone home screen now include Favorites, where you can search, copy and remove favorites, and click Original Message to jump back to where the message appears in the conversation.

### Improvements

- **Plugins Page Shows Where Each Agent Is Installed** (Mac): The Plugins page now checks this Mac and remote hosts connected through Remote-SSH, and shows which host an agent is installed on. Plugins for agents installed only on a remote host are now installed automatically as well.
- **New Coding Agents Display Fully Without an App Update** (iPhone, Mac, Apple Watch): Session icons, how the agent is named in conversations, the options on confirmation cards, explanations for view-only sessions, and new kinds of conversation content are now provided by the plugin on your computer. Supporting a new agent only requires installing its plugin on your computer.
- **Session Buttons Match What Each Agent Supports** (iPhone, Mac): Buttons such as Permission Mode, Model and Effort, Compact Context, Subagents and Tests now appear only for agents that support them.
- **View-Only Sessions Explain Why** (iPhone, Mac): When a session is view-only, the message field now explains why — for example, when Qwen Code isn't running in tmux.
- **Update Prompt When a Newer App Is Needed** (iPhone): If a plugin on your computer requires a newer version of Kiteline to display fully, the home screen and the affected sessions show a prompt. Tap it to update in the App Store.
- **Session List Slides Over Conversations in Portrait** (iPad): In portrait, showing the session list no longer squeezes the conversations on the right, and split conversations keep their width. The list hides automatically after you choose a session. In landscape, the list and conversations still appear side by side.
- **Full-Height Interface** (iPad): The status bar is now hidden by default so Kiteline extends to the top of the screen. You can show it again in Settings > Appearance.

### Bug Fixes

- Fixed an issue where the Mac sidebar's context menu and the Session menu showed Claude Code–only actions such as Permission Mode and Compact Context for Codex and other sessions. The Interrupt menu item now shows the agent's name.
- Fixed an issue where text in conversations on Mac couldn't be selected and copied by dragging with the mouse.
- Fixed an issue where the version and capabilities on the Plugins page did not refresh until the next update check after a plugin was installed, rolled back, or turned on or off.
- Fixed an issue where a plugin version revoked by Kiteline stayed in use. Checking for updates now rolls back to the last working version automatically.
- Fixed an issue on iPad where the kite at the top of the session list was partly hidden and covered the To-Dos button.
- Fixed an issue on iPad where conversations went blank or jumped to a different place after showing or hiding the session list or rotating the screen. Conversations at the bottom now stay at the bottom, and conversations you've scrolled back through stay on the same message.
- Fixed an issue where pasted messages, including messages sent from your phone, showed extra markup in conversations.
- Fixed an issue on iPad where there was too much empty space below the buttons at the bottom of conversations.

- Fixed an issue where the buttons at the top of the image viewer on Mac were bunched in the middle and didn't look like buttons. The previous/next, zoom, copy, save, share and other buttons are now in the window toolbar, with the title on the left and the buttons on the right; when the window is narrow, the remaining buttons move into the » menu.
## 3.49.0 (2026-10-24)

### New Features

- **DeepSeek Harness Support** (iPhone, Mac, Apple Watch): Kiteline can now view and control DeepSeek Harness sessions, including the desktop app and the command-line version started in web mode. The session list shows their work status and latest reply, and you can view the full conversation, send messages and images, approve or reject actions, answer questions and interrupt. DeepSeek Harness approvals apply to a single action only, so confirmation cards do not offer "Allow, and Don’t Ask Again in This Session".
- **View Proma Sessions** (iPhone, Mac, Apple Watch): While Proma is open, the session list shows recently used Proma sessions, whether they are working and their latest reply, and you can view the full conversation. Proma does not yet offer remote control, so replies and confirmations still need to be made in Proma on your computer.
- **New Plugins Page in Settings** (Mac): Lists the coding agent plugins Kiteline supports (Codex, OpenCode, DeepSeek Harness and Proma), with each plugin's version, whether its agent is installed on this computer, and what it can do in each form (CLI, VS Code extension, desktop app) on Mac, Windows and Linux: Read (view sessions and history), Write (send messages and add to a running turn), Execute (approve commands, answer questions and interrupt), or Read-only, along with whether it has been tested on that platform. Each plugin can be turned on or off; when turned off, Kiteline stops connecting to that agent and removes the Kiteline components installed in it.
- **Automatic Plugin Updates** (Mac): Kiteline regularly checks for new versions of official plugins and installs them automatically, so supporting a new coding agent or a new version of an agent no longer requires updating Kiteline. Remote hosts connected through Remote-SSH use the same plugins automatically, stored separately so they don't affect Kiteline installed on that host. Plugins are signed by Kiteline and only verified versions are installed; if a new version runs into problems, Kiteline rolls back to the last working version. Plugins you restore to the built-in version are no longer updated automatically. If a new plugin requires a newer Kiteline, the Plugins page offers "Update and Install" and installs the plugin once Kiteline has been updated.
- **Error Reports for Plugins** (Mac): When a plugin runs into a problem, a notice appears in the top-right corner of the screen (without switching away from your current window), and you can choose to send an error report from your own email app. The report includes only the plugin and agent versions, your system, and where the error occurred, with no conversation content, and you can review it before sending.
- **Zoom In and Out on Images** (Mac): The image viewer supports pinch to zoom on the trackpad, scrolling with ⌘ or ⌥ held down, and double-clicking to switch between Fit to Window and Actual Size; once zoomed in, drag to look around. You can also use the zoom buttons at the top, or press ⌘+, ⌘-, ⌘0 (Actual Size) and ⌘9 (Fit to Window). Image files in the Files panel, and screenshots attached in the message box, new tasks and to-dos, can also be clicked to view them larger.

### Improvements

- **Panels Can Be Moved and Resized** (Mac): Files, Changes, Tests, Agent map, Session Info, Search in Conversation, Permission Mode, Model, New Task, To-dos, the image viewer and confirmations now open as separate small windows centered on the conversation they belong to (the pane in a split view). Drag the title bar or any empty area to move them anywhere, drag an edge or corner to resize them, and keep viewing and using the conversation while a panel is open.
- **Claude Code Avatar Uses Its Logo** (Mac): In conversations, the Claude Code avatar now shows the Claude Code logo instead of the ✳︎ character, consistent with other agents.
- **No Confirmation Needed When Switching Sessions** (Mac): When Kiteline switched sessions or started a new task, a newly installed VS Code first asked whether to allow the Claude Code extension to open a link and whether to allow an external application to open the project folder, so messages couldn't get through while you were away from your computer. Kiteline now allows the Claude Code extension to open links automatically, and opening project windows no longer asks for confirmation. If VS Code still shows a confirmation, Kiteline keeps VS Code in the foreground and lets you know on your phone so you can respond on your computer.
- **Know What VS Code Is Waiting For When Starting Tasks** (Mac): When you start a new task from your phone and the project folder isn't trusted in VS Code yet (VS Code opens it in Restricted Mode, where the Claude Code extension doesn't run), or VS Code shows a dialog that needs your attention on the computer, Kiteline tells you on your phone right away what's wrong and what to click, instead of reporting after 45 seconds that the task couldn't be submitted.
- **New Readiness Check: VS Code Allows Claude Code Links** (iPhone, Mac): Shows whether Kiteline can switch sessions without VS Code asking for confirmation. If it can't be set up automatically, it lists the steps to take on your computer.
- **Smoother First Use of VS Code** (Mac): When Kiteline opens VS Code for the first time, it skips VS Code's sign-in welcome screen so it doesn't block your new task.
- **OpenCode Switch Moved to Plugins** (Mac): "Install the Kiteline plugin for OpenCode" in Settings > General is now managed by the OpenCode switch on the Plugins page. If you turned it off before, it stays off.

### Bug Fixes

- Fixed an issue where the context usage of OpenCode sessions was shown as 100% in the session list.
- Fixed an issue where a confirmation shown by VS Code while Kiteline was switching sessions was covered by other windows before you could click it, so it seemed to disappear on its own.
- Fixed an issue where, in the English interface, the result shown after starting a new task or resuming a conversation from your phone didn't read correctly.

## 3.48.1 (2026-10-24)

### Bug Fixes

- Fixed an issue where, with Reduce Motion turned on in macOS, the dashed lines between sessions in the session list didn't flow and the kite didn't fly. These effects are now controlled by the switches in Kiteline Settings → General → Messages Between Sessions.
- Fixed an issue where Kiteline on Mac quit immediately after launch when the same Claude Code session was open in two VS Code windows at the same time.
- Fixed an issue where, after Claude Code automatically compacted the context, the summary of the earlier conversation appeared in the conversation as a message sent by you. It now appears as "Context compacted"; open it to view the summary.

- Fixed an issue where View Full Transcript for a subagent in the Agent map was always empty.
- Fixed an issue where, in the English interface, notices in conversations such as API errors and interruptions still appeared in Chinese, and project status labels on the Projects page included Chinese text.

## 3.48.0 (2026-10-23)

### New Features

- **Kite Messenger** (iPhone, Mac): When one Claude Code session messages another with SendMessage, a kite flies across the session list from the sending session to the receiving one, trailing a kite line, and a ripple spreads around the receiving session's avatar as it lands. When the sessions are open in split panes on the Mac, the kite flies between their tabs. If the receiving session isn't on screen, the kite flies to the edge of the list and shows that session's name. Tap it to open the session.
- **Kite Lines** (iPhone, Mac): In the session list, dashed lines link sessions that exchanged messages in the last 15 minutes. The dashes keep flowing in the direction of the message, with arrows pointing to the receiving session: lines to sessions above run along the left of the avatars, and lines to sessions below run along the right. Older lines gradually fade.
- **Letters in Conversations** (iPhone, Mac): Messages a session sends and receives appear in the conversation as letters: the heading shows which session it's to or from, a kite postmark in the corner shows when it was sent, followed by the subject, body and signature, marked Delivered, Read, Replied or Not Delivered. Tap the heading to jump to the other session.
- **Messages Between Sessions on Apple Watch** (Apple Watch): Session details list the latest messages the session sent and received.
- **Choose Which Effects to Show** (iPhone, Mac): Turn Kite Messenger, Kite Lines and letters in conversations on or off individually in Settings → Messages Between Sessions on iPhone, or in Kiteline Settings → General → Messages Between Sessions on the Mac.
- **Service Notices and Update Alerts** (iPhone): Important notices, such as scheduled maintenance, appear at the top of the session list. Tap one for details, or dismiss it. When a new version is available on the App Store, an alert appears at the top of the session list and in Settings → About. Tap it to update.
- **Update Check** (Mac): When a new version is available, a green arrow appears at the bottom of the main window's sidebar (it's hidden when there's no update). Click it to see what's new. Once you confirm, the update downloads in the background with a progress bar and installs automatically, and Kiteline asks you to restart to start using it. Choose Later to finish the update the next time you quit Kiteline. You can also choose Kiteline → Check for Updates… at any time.
- **Open at Login** (Mac): The first time you run Kiteline after installing it, Open Kiteline at Login is turned on. You can turn it off in Settings → General.

### Improvements

- **Automatic Connection to Remote Projects** (Mac): When you start a new task, resume a session or open a project in VS Code for a project on a Remote-SSH host, Kiteline opens VS Code if it isn't already running, connects to the host and opens the project folder. If the Remote-SSH extension isn't installed in VS Code, it is installed automatically. If the Claude Code extension isn't installed on the remote host, it is installed there automatically (about 1 minute the first time) before the session starts. If the host's key file is set only in Kiteline, you're prompted to add it to your SSH configuration.

### Bug Fixes

- Fixed an issue where pinyin not yet converted with a Chinese input method could suddenly disappear from the conversation input field on Mac. The input field now also grows when the text being composed wraps to a new line.
- Fixed an issue where VS Code windows opened by Kiteline could fail to connect when the Remote-SSH host address included a user name or uppercase letters, or used a non-default port.

## 3.47.0 (2026-10-23)

### New Features

- **Interface Language Follows the System** (iPhone, Mac, Apple Watch): When the language is set to Follow System, Kiteline appears in Chinese on a Chinese system and in English on any other language. You can still choose Simplified Chinese or English manually in Settings.
- **English on Apple Watch** (Apple Watch): Apple Watch and its complications follow the language selected on iPhone.
- **Daily Report and Morning Briefing in Each Phone's Language** (iPhone, Mac): The daily report and morning briefing are written in the language selected on each phone. Notifications on the Mac follow the Mac's interface language.

### Improvements

- **English Interface Refinements** (iPhone, Mac): Counts now use singular and plural forms (for example, 1 file, 3 files). Longer English labels on buttons, segmented controls and summary cards have been resized or reworded so they're no longer cut off. Chart legends, source connection notices and computer text in demo mode now also appear in English.

## 3.46.0 (2026-10-23)

### New Features

- **English Interface** (iPhone, Mac): You can now switch the interface language to English in Settings: on iPhone, go to Settings → Appearance → Language; on the Mac, go to Kiteline Settings → General → Appearance → Language. The change takes effect immediately without restarting, and iPhone and Mac are set separately. Once switched, interface text, alerts and status from your computer, readiness checks, release notes, the activity log and system permission descriptions are shown in English.
- **Push Notifications in Each Phone's Language** (iPhone): Lock-screen notifications are sent in the language selected on each phone.

## 3.45.0 (2026-10-22)

### New Features

- **New Brand Mark: Kite** (Mac, iPhone, Apple Watch): The app icon is now a solid-color, paper-cut Beijing swallow kite flying diagonally toward the upper right, with the two strings at its chest converging into a single kite line. The launch screen, onboarding, subscription page and Mac menu bar icon are updated to match.
- **Kite at the Top of the Window** (Mac): A kite sits at the top of the main window, with its head and wingtips extending above the top edge of the window. It drifts up and down and sways side to side in the wind, and its kite line hangs down to the top of the sidebar. Its color follows the accent color. The kite does not respond to the mouse, and its animation pauses when the window is obscured. It can be turned off in “Settings → General → Appearance.”
- **Kite at the Top of the Home Screen** (iPhone): A kite flutters in the navigation bar at the top of the session list, with its color following the accent color. It flies away when the list is scrolled or searched, and flies back when the list returns to the top. It can be turned off in “Settings → Appearance → Accent Color, Font and Text Size.”

- **VS Code in a Virtual Screen** (Mac): Click the display button in the menu bar panel or at the lower left of the main window to move the VS Code window to an invisible virtual screen. When Kiteline sends messages or handles approvals, VS Code no longer appears in front of you, and the mouse does not enter the virtual screen. To view VS Code, click the button again or click “Open in VS Code” to move the window back; when Kiteline quits, the window automatically returns to its original position. This can also be turned on or off in “Settings → General.”
- **Support for Codex and OpenCode** (iPhone, Mac, Apple Watch): In addition to Claude Code, Kiteline can now view and operate sessions of OpenAI Codex and OpenCode. The session list shows their working status, latest reply and context usage; the conversation page shows the full conversation, the commands run and file changes; commands that need approval can be allowed or denied directly, and questions can be answered directly; you can also send messages (including images) or interrupt the current operation. No keystroke simulation is needed, and Codex or OpenCode does not need to be in the foreground. Computers connected through SSH are also supported. Codex terminal sessions, the VS Code extension, and Codex sessions in the ChatGPT desktop app are all supported with no setup required. Kiteline installs a plugin for OpenCode automatically, which takes effect after OpenCode is restarted; it can be turned off in “Settings → General → Agent Integration.”
- **Agent Icons and Grouping by Agent** (iPhone, Mac, Apple Watch): The session list, menu bar panel and conversation page title show the icon of the agent that owns each session (such as Claude Code), so sessions are easy to tell apart when several agents are in use. View Options adds a “By Agent” grouping, and search also accepts an agent name to find sessions.
- **Session Tabs** (Mac): At the top of each split on the right is a row of tabs, used the same way as in a browser. A session opened from the left sidebar opens in a new tab in the current split; the tab stays after you switch, click it to switch back, and click × to close it. Click “+” to create a new tab. Drag tabs to reorder them, move them to another split, or drag them to the edge of a split to separate them out. Right-click a tab to close other tabs or the tabs to its right. ⌘T creates a new tab, ⌘W closes a tab, ⌃⇥ / ⌃⇧⇥ or ⇧⌘] / ⇧⌘[ switches tabs, and ⌘1 through ⌘9 jump to a tab. Closing the window is now ⇧⌘W.
- **Computer Status** (iPhone, Mac): In the session list, the CPU usage and memory usage (used / total) of the computer are shown to the right of the machine name and updated every 5 seconds; the ring turns orange or red when usage is high. The computer name below the page title, the group headers when grouped by source, and the computer name beside each project group are all shown with it. Tap to view detailed figures such as the CPU core count and available memory. Computers connected through SSH are also supported, and the status appears in the group headers of the Mac main window sidebar.

### Improvements

- **Tab Bar Replaces the Window Title Bar** (Mac): The Files, Changes, Tests and Open in VS Code buttons have moved to the tab bar of each split. The top row of tab bars now shares a line with the window title bar, giving the conversation area more room. Context usage is now shown uniformly below the input field. When a split is narrow, the buttons are automatically collected into a More menu. The horizontal and vertical split buttons are now square icons.
- **Attach Images to New Tasks** (Mac): The New Task panel now uses a multi-line text field and supports Dictation. Press ⌘V in the text field to paste a screenshot, drag images into the panel, or choose images from Files or Photos, up to 6 images. Scheduled tasks also support this. Press Return in the text field to start a new line, and press ⌘↩ to start.
- **Paste Clipboard Images into New Tasks** (iPhone): When the clipboard contains an image, the image attachment row of a new task shows a Paste button.
- **Sidebar Selection Style** (Mac): Selected items in the left session list now use a light accent-color background with a thin border, matching the entries at the top. They no longer display a solid, highly saturated background.
- **Kite While Thinking** (Mac, iPhone, Apple Watch): While Claude is working, the status line on the conversation page, the badge on the session list avatar and the working status on the watch are replaced by a small kite that sways in the wind and moves closer and farther away. Its color follows the accent color.
- **Return to the Previous App After Sending** (Mac): After sending a message, handling an approval or creating a new task from Kiteline or the phone, the foreground is returned to the app you were using before, instead of staying in VS Code.
- **Redesigned Add to To-Dos Panel** (Mac): The title and source are placed at the top. The to-do content uses a multi-line text field: Return starts a new line, ⌘↩ adds the item, and Esc cancels. Screenshots can be dragged directly into the panel, pasted with ⌘V in the text field, or chosen from Files or Photos. Hover over a thumbnail to remove it.
- **Dictation** (Mac): When recording or editing to-dos, answering Claude's questions or creating a new task, click “Dictation” or the microphone button to start speaking. Click again to transcribe the speech into text, which is appended after the content already entered. On first use, allow Kiteline to access the microphone.
- **Uninterrupted Connection When Switching Networks** (iPhone): With Remote Access turned on, when switching between Wi-Fi and cellular, the connection moves to a new route in the background, so conversations and live status are no longer interrupted. When on the same Wi-Fi as the computer, the app connects directly; after leaving that network, it connects through the relay, and when Wi-Fi is available again, it automatically resumes a direct connection. It also reconnects faster when the signal is unstable or the network recovers.
- **Interface Text Applies to All Agents** (iPhone): The onboarding screens, the subscription page and the system permission descriptions shown on first launch no longer mention only Claude. They now apply to Claude Code, Codex and OpenCode alike.
- **Demo Mode Update** (iPhone): Sample sessions now include Codex and OpenCode, so you can try the full flow of to-do recognition, adding to To-Dos and jumping back to the original message. Sample images in conversations display correctly.
- **Remember Split Layout** (Mac, iPad): The layout of the right-hand split, the tabs open in each split and the position of the divider are saved automatically. After quitting or updating Kiteline, reopening it restores them as they were.
- **Pause Reading Aloud While Recording** (iPhone, iPad): With Read Aloud turned on, nothing is read aloud while you hold to talk or dictate, and any content being read stops immediately. New replies and updates from other sessions received during recording are read aloud in order after recording ends.

### Bug Fixes

- Fixed an issue where, when creating a new task or clicking “Open in VS Code,” a project not yet open would replace the most recently used VS Code window and interrupt the running sessions in it. Such projects now always open in a new window.
- Fixed an issue where clicking “Open in VS Code” for a local session opened the project folder in Finder instead of VS Code.
- Fixed an issue where, after Wi-Fi was disconnected, iPhone could not connect to the computer and required the app to be reopened to recover.
- Fixed an issue where, if you released the Hold to Talk button too quickly, or if recording was interrupted by a phone call or Control Center, the microphone kept recording.

## 3.44.0 (2026-10-22)

### New Features

- **Support for iPhone Duo Foldable**: When closed, the top of the home screen shows an overview dashboard with today's usage and the number of sessions that are running, awaiting approval, have new messages or have errors. When open, the left column shows the session list and the right column shows session details. When half-folded, the conversation page is split along the crease into a message area and a status and input area.
- **Pairing Can Be Completed Through the Relay**: When Remote Access is turned on, scanning the QR code to pair also tries both the local network and the relay. When entering a pairing code, if the computer cannot be found on the local network, pairing can be completed through the relay, and you must tap Allow on the computer to confirm. At any one time, a pairing code corresponds to only one computer.
- **iPhone Launch Screen**: When the app opens, it shows the brand launch screen and transitions to the home screen with an animation, so a brief black screen no longer appears. When Reduce Motion is turned on, the screen only fades out.
- **Paste Clipboard Images** (iPhone): When the clipboard contains an image, the input bar and the To-Dos “Attach Screenshot” option show a Paste button. Tap it to attach the image.
- **To-Do Attachments and Image Storage** (Mac): The To-Dos “Attach Screenshot” option supports choosing image files or dragging images in directly. When viewing a large image, “Save…” (which saves the original image) and “Share” are now available.
- **Ignore All To-Dos at Once** (iPhone, Mac): On the To-Dos page under “Not Yet Added,” when there are two or more items, you can ignore them all at once. Newly recognized items will still be prompted afterward.

### Improvements

- **Redesigned Mac Sidebar** (Mac): Today, To-Dos, History, Usage and Projects are now entry cards in two columns, showing icons, counts and brief descriptions. A red badge appears on To-Dos when there are newly recognized items. Usage refreshes automatically every 5 minutes. The “Sessions” column adds the same view options as on iPhone (grouping, sorting and filtering by computer) as well as status filtering, and pinned sessions are listed first.
- **Mac Sidebar Bottom Buttons** (Mac): The Sources, phone count, QR code and Settings buttons are enlarged. Each one opens its corresponding settings page when clicked.
- **More Relaxed Conversation Layout** (Mac, iPhone): The padding inside bubbles and tool step cards is increased, and the spacing between messages as well as between paragraphs, lists, code blocks and tables is increased. Bubbles for short replies are sized to the width of the text.
- **More Accurate Voice Transcription** (Mac): Mandarin now uses the Fun-ASR-Nano model, which runs offline on this computer. It significantly improves the recognition of proper nouns and punctuation, and recordings never leave the computer. The model is about 1 GB and is downloaded automatically on first use. Until the download completes, or if recognition fails, the system speech recognition is used automatically. Cantonese, Taiwanese Mandarin and English continue to use system speech recognition. Commonly misrecognized product names (such as Claude Code, Kiteline and VS Code) are corrected automatically.
- **Smoother Scrolling in Long Conversations** (iPhone): Status updates now refresh only the relevant parts, new content is deferred while scrolling, and messages off-screen no longer keep their rendered results. Stuttering and memory use in long conversations are noticeably reduced.
- **Thumbnails for Conversation Images** (iPhone): Images in conversations first show a thumbnail. Tap it to load the original image, which shows its file size and download progress. If loading fails, it retries automatically.
- **Automatic Connection Route Selection** (iPhone): The local network and the relay are both probed, with the local network preferred. When the local network is unavailable, the app switches to the relay immediately, and it switches back automatically when the local network recovers. The status of both routes is shown in “Settings → Connection.”
- **Relay Service Upgrade**: The relay service for Remote Access has been moved to a server with higher bandwidth. The address and how it is used remain unchanged.
- **No Longer Limited to Mac**: Instructions in iPhone and Apple Watch now uniformly use “computer.” Settings paths specific to macOS are shown only when connected to a Mac. On the pairing page, the list of computers supports horizontal swiping when several are found.
- **Formal Interface Wording**: Interface text, prompts and push notification titles on Mac, iPhone and Apple Watch now use formal wording throughout.
- **Redesigned Pairing Page** (iPhone): The page adopts a graphite background, neutral glass and thin borders. The onboarding screens shown on first launch have been adjusted to match.
- **To-Do Hint Card**: Tap anywhere on the card to view the recognized items and add them to To-Dos.
- **Release Notes as a Timeline**: Entries are grouped under New Features, Improvements, Bug Fixes and Security, with text in formal language. On Mac, release notes open in a separate window within the app (“Settings → About → Release Notes,” or the menu “Kiteline → Release Notes…”) instead of a browser.

### Bug Fixes

- Fixed an issue where ⌘V could not paste screenshots into the conversation input field on Mac. PNG, TIFF, JPEG, HEIC, GIF and WebP formats are now supported.
- Fixed an issue where “Share” did not respond when viewing a large image on iPhone. The top-right corner now offers “Save to Photos” and “Share,” and long-pressing an image also allows sharing. Both use the original image.
- Fixed an issue where viewing a large original image over the local network kept loading and never displayed.
- Fixed an issue where connecting through the relay failed after leaving Wi-Fi, requiring the app to be reopened (iPhone).
- Fixed an issue where the Mac HTTPS service stopped responding after a system network service error, requiring Kiteline to be restarted. It now recovers automatically.
- Fixed an issue where the conversation page could be dragged left and right.
- Fixed an issue where, after splitting the Mac main window, adjusting the window width caused layout errors and high CPU usage. The minimum width of each split column is now 320.
- Fixed an issue where new messages in the conversation page occasionally did not appear, leaving large blank areas (iPhone, Mac).
- Fixed an issue where sending content to a VS Code session that had not yet received a message would put the message into a newly opened blank tab. When the target session cannot be determined, VS Code is no longer operated on, and the reason is explained.
- Fixed an issue where the version number shown on the Mac About page was lower than the actual version.
- Fixed an extra space in the “Unable to Connect to Computer” message.

### Security

- The plaintext HTTP port is now open only on this computer, and only HTTPS is provided on the local network. The QR code in Phone Access is now an HTTPS link (Mac, Windows, Linux).
- The pairing QR code now uses a one-time pairing token (valid for 10 minutes and invalidated once one device has paired) and no longer contains the master token.
- Images with more than 60 million pixels are no longer decoded, preventing abnormal images from exhausting the memory of the computer or iPhone.
- Push subscriptions now accept only push tokens from the iPhone app and HTTPS addresses from browser push services, and limit the number of subscriptions per device.
- Access to the data directory (containing tokens, private keys and logs) is restricted so that only the current user can read and write it.

### Removed

- The desktop app no longer provides a web app. Visiting the local service address in a browser shows only connection instructions; please use the Kiteline app on iPhone. The Windows and Linux console has likewise removed “Open Web App.”

## 3.43.0 (2026-10-21)

### New Features

- **To-Dos**: When Claude's reply includes items that need your attention, a prompt below the message reads “N things need your attention.” You can check the items, edit them, and add them to To-Dos. You can also touch and hold any Claude reply to add it manually.
- **To-Dos Page** (iPhone, Mac): Items are grouped by their source message. Tap an item to go to the original message. You can mark items as done, delete them, edit them, and add them manually. To-Dos are saved on your computer and sync across your devices in real time. They remain viewable while offline.
- **To-Do Reminders**: When a running session identifies a new item, the Today card and the in-app banner show a prompt. Task-completion notifications also include the number of pending items.
- **To-Do Editing**: Uses a multiline text field, with support for Hold to Talk and attaching up to 9 screenshots.

### Improvements

- When answering Claude's questions, you can use Hold to Talk after selecting “Other.” The Quick Replies text field now supports multiple lines.

### Bug Fixes

- Fixed an issue where the iPhone app did not receive banner alerts while in the foreground and the notification count did not increase.

## 3.42.0 (2026-10-21)

### New Features

- **Renamed to Kiteline**: The product has been renamed from TARS to Kiteline, and the app icon and Mac menu bar icon have been updated. Your data, pairings, and system permissions are kept after upgrading, so you do not need to pair your phone again. On first launch, macOS may request local network access again.
- **Mac Signing and Notarization**: The Mac app is a universal app that supports Apple silicon and Intel models (macOS 14 or later). It is signed with Developer ID and notarized by Apple.
- **Apple Watch App**: Raise your wrist to view actions awaiting approval and to allow or deny them. Supports permission confirmation, plan approval, and answering questions. On Series 9, Ultra 2, and later models, you can use Double Tap to allow; dangerous commands require a second confirmation. You can also view the session list and details, reply to or interrupt sessions, check usage, and use four watch face complications. The watch connects to your computer through iPhone and refreshes only when you raise your wrist, to save battery.
- **Apple Watch Settings**: Adjust watch options in “Settings → Apple Watch” on iPhone, or in “Kiteline Settings → Apple Watch” on Mac. Settings stay in sync on both devices.
- **Session Split View** (Mac, iPad): Split the session area into multiple panes, nested as you like (up to two on iPad). Drag sessions in from the sidebar, and drag the divider to resize panes.
- **Wide-Screen Split Layout** (iPad, iPhone): The session list appears on the left, and the conversation appears on the right.
- **Voice Input for New Tasks**: The input fields for new tasks and scheduled tasks support Hold to Talk.
- **Privacy Policy, Terms of Use, and Support Pages**: View them in “Settings → About” on iPhone, on the subscription page, and in “Kiteline Settings → About” on Mac. They are available in both Chinese and English.

### Improvements

- **Native Conversation View on Mac**: The Mac conversation view now uses the same interface as the iPhone app. Press Return to send, press ⌘V to paste screenshots, or drag in images. Files, Changes, and Tests panels open one layer at a time, and you can press Esc to close them.
- **Expanded Mac Menus**: Added “Settings…” (⌘,), “New Task…” (⌘N), “History” (⌘Y), and a “Session” menu (Search, Project Files, Changes and Test Reports, Session Info, Permission Mode, Model, Compact Context, Interrupt, and more).
- **Mac Interface Details**: The Settings window is wider, so all tabs are visible at once. Panels now share a consistent style, with the title at the top left and “Done” at the bottom right. Tips appear above all other content and are no longer hidden by panels. History supports grouping.
- **More Reliable New Task Submission**: The Mac app clicks the send button in a new VS Code tab directly, so tasks can be submitted even when VS Code is not in the foreground. If a task cannot be submitted within 45 seconds, a push notification is sent with the reason.
- Before sending a message or handling an approval, if another app has moved VS Code to the background, the Mac app first brings it back to the foreground.
- Messages in pop-up pages now appear on top and are no longer obscured.
- When you send content to an empty session that has not yet received any messages, the prompt explains the reason and how to resolve it.

### Bug Fixes

- Fixed an issue where an unreviewed command could be approved if Claude moved to the next approval request at the moment “Allow” was tapped (iPhone, Apple Watch). The app now checks the pending request before acting, and if it has changed, the action is not performed and a message is shown.
- Fixed an issue where keystroke requests were automatically resent after a network timeout. Requests are now resent only when it is confirmed that they were not sent, and an explicit notice appears when the outcome is uncertain.
- Fixed an issue where the conversation page could be stretched wider when there were many labels below the input bar or when the text size was large.

### Security

- Relay server logs no longer record IP addresses or device identifiers.

## 3.41.2 (2026-10-20)

### New Features

- **Kiteline Pro Subscription** (iPhone): The free version lets you view sessions over the Wi-Fi network your computer is on. With a subscription, you can use Kiteline on any network, reply, use voice input, send images, handle approvals, and create new tasks. Monthly and annual plans, a free introductory trial, and Restore Purchases are available.
- **Quick Attach for Recent Screenshots** (iPhone): When you tap “+,” a preview of any screenshot taken within the past 3 minutes appears above the button. Tap the preview to attach it.
- **Pasting Screenshots on Mac**: Press ⌘V to paste a screenshot directly, or paste an image copied from Finder. The Edit menu is also now complete.
- **Renaming Sources** (Mac): You can rename each computer in “Settings → Sources,” and the new name is shown on your phone.
- **Appearance Settings** (iPhone): Choose Follow System, Light, or Dark.
- **History Grouping** (iPhone): Group sessions by date, source, or project.

### Improvements

- Updated the iPhone interface with two-color icons. Removed the banner that covered messages, and moved the task list and stall notices to the input area. Only the Stop button beside the input field is kept. Spacing in the bottom input area is now consistent, and the conversation title bar has been simplified.
- Pop-up sheets now adjust their height to fit their content.

### Bug Fixes

- Fixed an issue where the thinking level shown on the phone did not match VS Code.
- Fixed an issue where releasing a drag in a pop-up or list could accidentally trigger a button (iPhone).
- Fixed an issue where the Mac menu bar icon disappeared.
- Fixed an issue where the Permission Mode pop-up had too much empty space at the bottom.

## 3.41.1 (2026-10-20)

### Improvements

- **Faster Connections on Cellular Networks** (iPhone): On a cellular network, the app connects directly through Remote Access instead of trying local network addresses one by one. After you switch networks, the app immediately reselects the connection route, and Settings shows the current route.
- In the input bar, Permission Mode, Model, and Thinking Level are each shown as a single button, and the number of subagents is displayed. The Stop button has moved to the left of “+.”
- Quick Replies appear only while you are typing.
- Tap a file name in a message to open it. The Files page now includes “Change History.”

### Bug Fixes

- Fixed an issue where releasing a drag in a bottom sheet could accidentally trigger a button (iPhone).

## 3.41.0 (2026-10-20)

### New Features

- **Subagents and Background Tasks**: View the status, tasks, tool calls, and results of subagents started by the main agent, as well as the output of background commands.
- **Switch Permission Mode**: Change a session's permission mode on your phone (Manual, Auto-Edit, Plan, Auto), and view the current mode.

## 3.40.1 (2026-10-20)

### Bug Fixes

- Fixed an issue where pauses in a longer voice message while holding to talk caused only the last sentence to be kept.

## 3.40.0 (2026-10-20)

### Improvements

- **Remote Access Uses the Kiteline Relay by Default**: No extra setup is required. You can also switch to a relay server you host yourself in Settings → Remote Access.

## 3.39.0 (2026-10-20)

### New Features

- **Peer-to-Peer Remote Access**: A Tailscale account is no longer required. When you pair your phone with your computer, they exchange keys. Afterward, the connection is made directly whenever possible on any network, and relayed when a direct connection is not possible. All traffic is end-to-end encrypted. Disabling a device immediately disconnects its remote connections.

### Improvements

- The installation package is about half its previous size.

## 3.38.0 (2026-10-20)

### New Features

- **Remote Access**: After you enter a Tailscale key, your phone can connect to your computer even when it is not on the same Wi-Fi network. Replaced by Peer-to-Peer Remote Access starting with 3.39.0.
- **Local Network Pairing**: The iPhone app automatically discovers Macs on the same Wi-Fi network. Enter the 6-digit pairing code to complete pairing.

## 3.37.5 (2026-10-20)

### Improvements

- The pairing QR code now includes the fingerprint of the computer's certificate. The iPhone app verifies it and can establish an encrypted connection without installing a certificate profile.

## 3.37.4 (2026-10-20)

### New Features

- **Paste Screenshots**: Tap the “+” in the input bar, then choose “Paste Screenshot” or “Choose from Library.”

## 3.37.3 (2026-10-20)

### Improvements

- When an image fails to load, the app now switches to a direct download immediately, so images display faster.

## 3.37.2 (2026-10-20)

### Bug Fixes

- Fixed an issue where conversation images sometimes could not be displayed on iPhone. When a download fails, the specific reason is now shown and logged.

## 3.37.1 (2026-10-20)

### Improvements

- After the computer app is updated, the page on iPhone updates automatically without reopening it.

### Bug Fixes

- Fixed an issue where an error in the iPhone image cache prevented conversation images from displaying.

## 3.37.0 (2026-10-20)

### Improvements

- **Adopts the iOS 27 Liquid Glass Design**: The navigation bar, input bar, menus, panels and banners now use Liquid Glass. When Reduce Transparency is turned on, solid backgrounds are used instead.

## 3.36.1 (2026-10-20)

### Improvements

- Notifications are no longer duplicated: while the app is in the foreground, only the in-app banner is shown. Push notifications are sent only when the app moves to the background or the screen locks.

### Bug Fixes

- Fixed an issue where sessions with the tag “Claude Code” could not send messages.

## 3.36.0 (2026-10-20)

### New Features

- **Avatar and Name**: In conversations, your messages show the computer account's avatar and user name by default. You can change them in Settings on iPhone or Mac, and choose a system avatar or a photo from your library.
- **Session List Grouping**: Sessions can be left ungrouped, grouped by source, or grouped by project. Groups can be collapsed; a collapsed group shows a notice when it contains sessions awaiting your approval or with errors.

### Improvements

- The Read Aloud button has moved to the conversation title bar, and a sound wave animation is shown while reading aloud.
- The session “⋯” menu has been redesigned: frequently used actions appear in a grid, thinking level and context usage show their current values directly, and Read Aloud and Mute are now toggles.

### Bug Fixes

- Fixed an issue where, with multiple sessions in the same VS Code window, messages sent from the phone could go to another session. The target session is now verified before sending and before each keystroke; if it cannot be confirmed, the message is not sent and a notice is shown.
- Fixed an issue where playback with the Microsoft voice failed and “Reading Aloud” remained displayed.
- Fixed an issue where a screenshot attached before holding to talk was not sent.
- Fixed an issue where your own screenshots could not be displayed after some time. Images that fail to load are now retried automatically.

## 3.35.0 (2026-10-20)

### New Features

- **Model and Thinking Level Display**: The top of the conversation page now shows the current model, thinking level, and context usage.

### Bug Fixes

- Fixed an issue where the title of the Mac Settings window appeared as “Untitled.”

## 3.34.0 (2026-10-20)

### New Features

- **Microsoft Neural Voices for Read Aloud**: Uses a near-human Microsoft Chinese voice by default. You can change the voice and adjust the speaking rate in “Settings → Read Aloud.” When the network is unavailable, the built-in voice of the computer is used automatically.
- **Thinking Level and Ultracode**: Adjust the thinking level or turn Ultracode on or off from the “⋯” menu of a session. Changes apply only to the current session.

### Improvements

- When a certificate is not trusted, Settings and the readiness check explain how to resolve it and show the certificate's actual name.
- Popup menus with many options now scroll.

## 3.32.2 (2026-10-20)

### Improvements

- Adapted for macOS 27: The “Accessibility” permission in all prompts is renamed to “Device Control and Data Access,” the name now used by the system.

## 3.32.1 (2026-10-20)

### Bug Fixes

- Fixed an issue where messages sent from iPhone could not be submitted in Claude Code extension 2.1.301 and later. When the required system permission is not granted, the phone now clearly indicates that the message was not sent and explains how to turn the permission on.

## 3.32.0 (2026-10-20)

### New Features

- **View Full-Size Images**: Switch between images left and right, show image numbers, and copy or save images. On a computer, use the arrow keys to switch and press Esc to close.

## 3.31.0 (2026-10-20)

### New Features

- **Activity Summary**: When you return to a session after being away for more than 10 minutes, a summary at the top shows the number of replies, changed files, tests, and images from that period. Tap to jump to where you last read.

## 3.30.0 (2026-10-20)

### New Features

- **Quick Interrupt**: While Claude is working, a Stop button appears in the input bar. Confirm to interrupt the current operation.
- **Stall Alerts**: When a session has made no progress for 20 minutes, a push notification is sent, and the session list and conversation page mark it as “Possibly Stalled” with an Interrupt button.

## 3.29.0 (2026-10-20)

### New Features

- **Error Alerts**: When Claude stops because of a usage limit, context length, API overload, or an expired sign-in, a push notification reports “Stopped with an Error” with suggested steps. The session list and conversation page show the same status.

## 3.28.0 (2026-10-20)

### New Features

- **Notification Inbox**: A new notification button in the upper-right corner of the session list gathers all alerts. It shows a badge when there are unread items and notes why an alert was not pushed to the Lock Screen. The most recent 300 items are kept and shared across all your phones.

### Improvements

- The morning briefing notes the number of alerts not pushed during Do Not Disturb.

## 3.27.0 (2026-10-20)

### Improvements

- The morning briefing adds project status, listing projects with uncommitted or unpushed changes.

### Bug Fixes

- Fixed an issue where tap actions in a conversation stopped working after touching and holding a message.
- Fixed an issue where Chinese file names appeared garbled in the change report and some file statuses were incorrect.
- Fixed an issue where the computer stopped responding while reading a network disk or waiting for system authorization.
- Fixed an issue where earlier results returning late overwrote newer content in a panel.
- Fixed an issue where a failed project list refresh cleared the content already shown.
- Improved overall stability and security.

## 3.26.0 (2026-10-20)

### New Features

- **Project Overview**: Summarizes projects on all your computers, showing running and awaiting-approval sessions, Git branches and changes, commit activity, and spending over the past 7 days. Projects can be filtered.
- **Project Details**: View running sessions, history, change reports, and files for a project, and start a New Task in that project.

### Improvements

- Change reports can now be viewed for sessions that have ended.
- Projects restricted by macOS folder permissions no longer hang when read. The project card and readiness check now explain how to grant access.

## 3.25.0 (2026-10-20)

### Improvements

- Data transfers are now compressed, so content loads faster on poor networks.

## 3.24.0 (2026-10-20)

### New Features

- **Pin Sessions**: Touch and hold or right-click a session to pin or mute it. Pinned and muted settings sync between iPhone and Mac.
- **Filter by Computer**: When sessions are spread across multiple computers, you can view the sessions from just one of them.

## 3.23.0 (2026-10-20)

### New Features

- **Message Menu**: Copy, reply with a quote, read aloud, share, and select text. Messages you sent can be resent, and images can be viewed at full size.

## 3.22.0 (2026-10-20)

### Improvements

- System permissions you have already granted (Accessibility and Speech Recognition) are now kept after an update, so you no longer need to grant them again. After installing this version, you will need to grant them once more.

## 3.21.0 (2026-10-20)

### New Features

- **Readiness Check**: Lists each setting and step required for full use, with instructions. When a key item is incomplete, a reminder appears at the top of the session list.

## 3.20.0 (2026-10-20)

### New Features

- **Do Not Disturb Hours** (23:00 to 08:00 the next day by default): During these hours, push notifications are sent only for messages that need your approval. Other alerts are combined into the morning briefing.
- **Mute Sessions**: A muted session sends push notifications only when it needs your approval.

## 3.19.0 (2026-10-20)

### New Features

- **Repeat Approval Reminders**: If an approval request is still unhandled after 10 minutes and again after 30 minutes, a push notification is sent again.
- **Morning Briefing** (08:30 by default): Summarizes the sessions awaiting approval and the progress made overnight in each session.

## 3.18.0 (2026-10-20)

### Bug Fixes

- Fixed an issue where messages with screenshots were missing from Today.
- Fixed an issue where the daily spending limit was not enforced when some computers were offline.
- Fixed an issue where scheduled tasks were skipped when a computer was temporarily offline.
- Fixed an issue where pressing Return during an automatic commit could type into another app.
- Fixed an issue where messages resent after a network recovery caused Claude to receive duplicates.
- Fixed an issue where tapping an approval card repeatedly could act on the next item awaiting approval.
- Improved overall stability and security.

## 3.17.0 (2026-10-20)

### New Features

- **Search Within a Session**: Search for content within a single session. Tap a result to jump to its location.
- **Release Notes**: View the changes in each version under “Settings → About → Release Notes.”

## 3.16.0 (2026-10-20)

### New Features

- **Separate Branches for New Tasks**: New tasks can run on a separate Git worktree branch, without affecting changes in progress in the main directory.

## 3.15.0 (2026-10-20)

### New Features

- **Offline Viewing**: When your computer cannot be reached, you can still view the session list and recently viewed sessions. Messages sent while offline are sent automatically once the connection is restored.

## 3.14.0 (2026-10-20)

### New Features

- **Daily Spending Limit**: When the limit is reached, scheduled tasks are skipped automatically, and new tasks and messages require confirmation before they are sent. Responding to approval requests is not affected.

## 3.13.0 (2026-10-20)

### New Features

- **Bark Backup Push**: Reminders can be received through Bark, with optional AES encryption. Bark complements system push notifications.

## 3.12.0 (2026-10-20)

### New Features

- **Scheduled Tasks**: Set a schedule to run every day, on weekdays, or once. When it is time, a new session is created automatically in the specified project and the request is sent. Tasks can be paused or run immediately, and their results are sent as push notifications.

## 3.11.0 (2026-10-20)

### New Features

- **Read Aloud**: Have Claude’s replies read aloud. With Read-Aloud mode turned on, new replies are read aloud automatically, along with approval requests and completion updates from other sessions.

## 3.10.0 (2026-10-20)

### New Features

- **Context Usage Alerts**: Get a reminder when context usage exceeds 80%, and compact the context with one tap.
- **Ask Claude to Commit or Push**: From the change report, ask Claude to commit or push your code.

## 3.9.0 (2026-10-20)

### New Features

- **Device Management**: Each phone uses its own device token, which can be viewed, renamed and revoked individually. Revoking a device disconnects it immediately.

## 3.8.0 (2026-10-20)

### New Features

- **Browse Project Files**: View files in the session’s working directory in read-only mode, with syntax highlighting, Markdown rendering, image preview and file name search. Sensitive files are shown only after confirmation.

## 3.7.0 (2026-10-20)

### New Features

- **Spending Alerts**: Receive a push notification when daily spending reaches 80% and 100% of your budget.
- **Activity Log**: Records every action taken on iPhone and Mac, including the time, target session, source device and result.

## 3.6.0 (2026-10-20)

### New Features

- **Usage Report**: Summarizes spending and token usage by day, model, project and computer.

### Improvements

- The home screen now offers three entries: “Today,” “History” and “Today’s Usage.”

## 3.5.0 (2026-10-20)

### New Features

- **History**: Browse past conversations on all computers.
- **Full-Text Search**: Search the content of all conversations; tap a result to jump to its location.
- **Resume Sessions**: Send a message in a session that has ended to resume it in VS Code.

## 3.4.0 (2026-10-20)

### New Features

- **New Task**: On your phone, choose a project and describe the work to start a new Claude Code session in VS Code. If the project is not open, it is opened automatically.

## 3.3.0 (2026-10-20)

### New Features

- **Quick Replies**: Common replies appear above the input field. Tap one to send it. Quick replies can be customized and are synced across devices.

## 3.2.0 (2026-10-20)

### New Features

- **Today**: Summarizes the conversations, changes, tests, screenshots and conclusions of each session over a given period.
- **Daily Report**: Delivers the day’s activity at a scheduled time each day.

## 3.1.0 (2026-10-20)

### New Features

- **Change Report**: View the branch, changed files, new files and recent commits of the Git repository where a session runs, and view diffs.
- **Test Report**: Automatically detects tests run in a session and summarizes the results.
- **Usage Display**: Shows each session’s context usage, token usage and number of requests.

### Improvements

- You can preview and remove attached images in the input field. Each message shows its send time. Tables and code blocks wrap automatically.

## 3.0.0 (2026-10-20)

### New Features

- **macOS App**: Provides a menu bar, a main window and Settings. Requires macOS 14 or later.
- **Hold to Talk**: Speech is transcribed offline on the computer.
- **Replies with Screenshots**: Claude can attach screenshots of the interface, test results and more to its replies.

## 2.0.0 (2026-10-20)

### New Features

- **Mobile App**: Provides a session list and a chat-style conversation view that shows messages, reasoning, tool calls and task progress in full. Approve permission requests, answer questions and approve plans, and send text and images.
- **Lock Screen Notifications**: Receive push reminders when approval is needed, a task finishes or an image arrives.
- **Secure Pairing**: Connect to your computer by scanning a QR code or entering a 6-digit pairing code. The connection uses HTTPS with a certificate issued by the computer itself.
- **Precise Delivery**: Automatically locates the VS Code window where a session is running and sends your message there. Supports sessions in Remote-SSH and tmux.

### Bug Fixes

- Fixed an issue where the session count in source status always showed 0.
- Fixed an issue where “Jump Back to VS Code” opened a new window when the hostname was written inconsistently.
- Fixed issues with the observer’s installation path and update detection on remote hosts.

### Removed

- WeCom notification channel.

## 1.1.0

Adds support for multiple sources (this computer and any Remote-SSH host) and a menu bar panel.
