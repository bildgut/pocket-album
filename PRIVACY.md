# Privacy Policy — Pocket Album

*Last updated: September 30, 2026*

Pocket Album is an unofficial iOS client for [Immich](https://immich.app/), a photo server
you host yourself. It is not affiliated with or endorsed by the Immich project.

## What the app collects

**Nothing.** The developer of Pocket Album receives no data from the app — no analytics,
no crash reports, no advertising identifiers, no tracking. The app contains no third-party
analytics or advertising code.

## Where your data goes

The app talks **only to the Immich server whose address you enter**. Photos, videos,
album and person names, locations and other metadata are loaded from that server and shown
on your phone. Changes you make (favorite, move to trash) are sent to that server.

## What is stored on your phone

- **Server address and API key** — in a file only the app can read, protected by iOS data
  protection and excluded from device backups.
- **Your password** — never stored. If you choose “sign in instead” during setup, it is sent
  once to your server to create an API key, then discarded.
- **Cached metadata and thumbnails** — so the app starts quickly and works offline.
- **Offline albums** — photos (as previews or originals) and videos of albums you choose to
  keep on the phone, excluded from device backups.
- **An account fingerprint** — a one-way hash of your server address and API key, so the app
  notices when you sign in to a different account and clears the previous account's cache.
  It can't be turned back into your key.

Delete the app to remove all of this. Signing out removes the server address and API key.

## Network security

Plain `http://` addresses are allowed so that servers on a home network or VPN work. In that
case your API key and photos travel unencrypted — use `https://` when you reach your server
over the internet.

## Children

The app is not directed at children and collects no data from anyone.

## Contact

Questions: [GitHub Issues](https://github.com/bildgut/pocket-album/issues).
