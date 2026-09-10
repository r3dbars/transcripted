# Issue 1681 review evidence

The existing Speakers review row now enables its play button when a matching,
bounded sample can be read from retained meeting audio. The layout is unchanged;
transcript rows remain static.

Native UI click/screenshot verification is incomplete. The no-prompt
`transcripted-qa permission-state --mode computer-use` probe reported that the
automation host lacks Accessibility/Event Posting permission. The owner's
existing app instance was left alone. No permission changes were requested.

Automated coverage uses synthetic fixtures only: scanner tests resolve raw and
styled speaker rows to the right retained channel, and muted AVPlayer tests
exercise actual sample playback, stop/replacement, and failure cleanup. These
checks do not prove the visible row behavior or reproduce the customer's audio.
