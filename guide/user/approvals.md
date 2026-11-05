# Approvals, plans and questions

[简体中文](approvals.zh-CN.md)

When an agent stops to wait for you, Kiteline sends it to your phone and watch.

## Commands and file changes

You see the exact command or change, then choose **Allow**, **Deny** or **Always Allow**. You can do it right from the lock screen notification.

High-risk commands, such as `rm -rf`, `git push --force` or `sudo`, always need a second confirmation. If a request is still waiting after 10 and 30 minutes, Kiteline reminds you again.

## Plans

When a Claude Code session in plan mode finishes a plan, read it on the phone and approve or reject it. You can switch a session into plan mode from the phone too.

## Questions

When an agent asks a multiple-choice question, the options become buttons. Tap one, or choose **Other** and answer in your own words, typed or spoken.

## Apple Watch

Raise your wrist to allow, deny or pick an option. Double Tap works on Series 9, Ultra 2 and later. Complications show what is waiting.

## Quiet hours

During quiet hours only approvals are pushed, so you aren't woken up by routine updates.

## Goals

A session with a goal (`/goal`) keeps working round after round until the goal is met. While it runs, you don't get a "finished" notification after every round; you hear about it when the goal is met, can't be met or stops partway, for example on an API error or a usage limit.
