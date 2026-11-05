# Privacy and security

[简体中文](privacy.zh-CN.md)

## What Kiteline never does

- Sign in to Claude or any other AI service.
- Read, store or forward your API keys, session tokens or logins.
- Call a model API.
- Modify your agents or their configuration.

Your agents keep running on your computer under your own account. Billing stays with your existing plans.

## What Kiteline adds

Four skills for your agents (screenshots, browser tests, to-dos and key info, task stages) and small plugins for plan limits and progress reminders. They live in each agent's own folders, never in your project, and each can be turned off. Playwright for browser tests is installed in Kiteline's own folder.

## Pairing and devices

There is no account. Each phone gets its own device token, stored on the computer only as a hash and revocable on its own. Pairing codes expire after 10 minutes and work once. Every action taken from a phone or watch is written to the computer's audit log.

## Where your data goes

Conversations and code travel only between your computer and your phone, end-to-end encrypted. See [Remote access](remote-access.md) for how the connection works.

## Usage statistics

Every 15 minutes the computer sends a summary to the Kiteline server: device types and versions, which agents and models are used, token counts and the display name you set, with all IDs hashed. It never includes conversations, code, file names, paths or session titles. Turn it off under **Settings → Send usage statistics**.

## Voice

Hold-to-talk transcription runs on your own computer (Mandarin offline with Fun-ASR-Nano); recordings never leave your devices. If you choose Microsoft voices for reading replies aloud, the text being read is sent to Microsoft to be synthesized.
