# Emacs-zulip: Zulip client in Emacs

Emacs-zulip is native Zulip client built in for Emacs. It leverages Zulip official API and build local cache / database to store current zulip state.

## Features
- login to zulip instance
- browse channels / topics / direct messages
- compose new messages in DM / channels / topics
- visualise tree of channels / topics
- menu of client contains easy to use navigation similar to mu4e or emmet (matrix client for Emacs).

It supports all the zulip functionality.

Must be compatible with core emacs as well as Doom / evil modes and should have appropriate keybindings

## Doom integration
must be able to install through packages.el. 
Must be able to add native shortcuts into doom keyboard layout

## Configuration
basic configuuration must be docummented
it must allow to connect to multiple zulip instance and switch the context between the instances
Readme with instructions must be ready to use by dummy users

## rules for testing
- you should test everything locally on this machine using emacs cli
- unit tests i. e. ERT must by present
- before each commit you have to run and pass all the tests
- code must be appropriate commented. 
