# NotificationKeys

Menu bar agent that makes macOS notifications keyboard-navigable. It reads and acts on the Notification Center (`com.apple.notificationcenterui`) through the Accessibility API.

## Build and run

```bash
./build.sh --install
open /Applications/NotificationKeys.app
```

`--install` replaces `/Applications/NotificationKeys.app`, where Spotlight finds it. On first launch, grant Accessibility access in System Settings > Privacy & Security > Accessibility.

`build.sh` signs ad-hoc with the designated requirement `identifier "local.notificationkeys"` instead of the default exact-cdhash requirement, so the Accessibility grant survives rebuilds. Any binary signed with that identifier matches the grant. If a grant was made for a build with the default requirement, reset it with `tccutil reset Accessibility local.notificationkeys` and grant again.

On first launch the app registers itself as a login item (`SMAppService.mainApp`). The menu bar item **Start at Login** turns that on and off; System Settings > General > Login Items shows the same setting.

## Keys

Global:

| Key | Action |
|-----|--------|
| ⌃⌥N | Toggle navigation mode. Opens Notification Center when no banner is on screen. |
| ⌃⌥⇧N | Clear all notifications, close Notification Center if open |

In navigation mode (selection shown as an accent-colored border):

| Key | Action |
|-----|--------|
| ↓ / j, ↑ / k | Move selection |
| Return | Perform the notification's default action, leave navigation mode |
| Space / → | Expand a stack, or "Show Details" |
| Delete / x | Close the selected notification (or clear its stack) |
| ⇧Delete / ⌘Delete / a | Clear all notifications, leave navigation mode, close Notification Center |
| Esc | Leave navigation mode, close Notification Center if NotificationKeys opened it |

Other keys pass through to the frontmost app.

## How it works

- Notifications: elements whose subrole starts with `AXNotificationCenter` (widgets excluded) or that expose a `Close` / `Clear All` action, sorted top to bottom.
- Open/close Notification Center: presses the clock menu extra (`AXExtrasMenuBar` item with identifier containing `clock`) of Control Center.
- Close / clear: performs the `Close` and `Clear All` named actions, repeating until no notification remains.
- Key capture: a `CGEventTap` that is installed only while navigation mode is active.

The Notification Center accessibility tree is private and changes between macOS releases; the subroles and action names above are the ones used on macOS 14–15 and are not verified on macOS 27.
