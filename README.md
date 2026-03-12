# Video Downloader

A focused iOS app for downloading supported videos from direct URLs, managing local storage, and gating extra usage behind a paywall.

## Features
- Direct-link input for supported file types (`mp4`, `mov`, `m4v`, `3gp`, `3g2`).
- Rights confirmation sheet before each download:
  - Shows the requested URL, trimmed to 200 characters
  - Requires three explicit `Yes` answers before the app starts downloading
- One free download per day for non-subscribers.
- StoreKit paywall with:
  - Weekly subscription
  - Monthly subscription
  - Lifetime one-time purchase
- Local download management:
  - Rename
  - Hide/unhide via passcode vault
  - Delete
- Dedicated video progress, cancellation, and status messaging.
- Persistence of downloads, entitlements, and vault passcode.

## StoreKit IDs
- `org.icorpvideo.VideoDownloader.weekly`
- `org.icorpvideo.VideoDownloader.monthly`
- `org.icorpvideo.VideoDownloader.lifetime`

## App Review Compliance Note
Guideline 5.2.3 is not satisfied by a generic third-party media downloader on its own. The current binary no longer hard-restricts downloads to one approved domain. Instead, it requires the user to complete a rights confirmation sheet before every transfer.

How the current binary works:
- `SupportedFormatResolver` validates the URL scheme and file extension.
- When the user taps `Download`, the app opens a modal confirmation flow instead of starting the network transfer immediately.
- The modal shows the exact requested URL, trimmed to 200 characters for readability.
- The user must answer `Yes` to all three statements before `Confirm and Download` becomes available:
  - They requested this exact URL themselves.
  - The website allows them to download the file.
  - They received approval from the owner of the domain to download the file.
- If any answer is `No`, the app shows a warning that the user does not have permission to download the file and the transfer remains blocked.

Important limitation:
- This is a user attestation flow, not proof of license ownership.
- It may reduce accidental misuse, but by itself it does not prove legal rights to Apple or to a third-party rights holder.
- If you resubmit, App Review may still require documentary proof that the app is used only for authorized downloads.

## Showcase
Click any preview to open the high-quality screenshot.

<table>
  <tr>
    <td align="center">
      <a href="showcase/high/main-videos.png">
        <img src="showcase/preview/main-videos.png" alt="Main screen with five videos (light)" width="200" />
      </a>
      <br />
      <sub>Main Screen, 5 Videos (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/demo-link.png">
        <img src="showcase/preview/demo-link.png" alt="Demo link in input (light)" width="200" />
      </a>
      <br />
      <sub>Demo Link In Input (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/downloading-process.png">
        <img src="showcase/preview/downloading-process.png" alt="Downloading process (light)" width="200" />
      </a>
      <br />
      <sub>Downloading Process (Light)</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <a href="showcase/high/video-menu-opened.png">
        <img src="showcase/preview/video-menu-opened.png" alt="Video menu opened (light)" width="200" />
      </a>
      <br />
      <sub>Video Menu Opened (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/video-export-opened.png">
        <img src="showcase/preview/video-export-opened.png" alt="Video export submenu opened (light)" width="200" />
      </a>
      <br />
      <sub>Export Menu Opened (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/rename-file.png">
        <img src="showcase/preview/rename-file.png" alt="Rename file modal (light)" width="200" />
      </a>
      <br />
      <sub>Rename File (Light)</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <a href="showcase/high/vault-unlock-modal.png">
        <img src="showcase/preview/vault-unlock-modal.png" alt="Vault unlock modal (light)" width="200" />
      </a>
      <br />
      <sub>Vault Unlock Modal (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/vault-unlocked-videos.png">
        <img src="showcase/preview/vault-unlocked-videos.png" alt="Unlocked vault with videos (light)" width="200" />
      </a>
      <br />
      <sub>Vault Unlocked (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/main-videos-dark.png">
        <img src="showcase/preview/main-videos-dark.png" alt="Main screen with five videos (dark)" width="200" />
      </a>
      <br />
      <sub>Main Screen, 5 Videos (Dark)</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <a href="showcase/high/demo-link-dark.png">
        <img src="showcase/preview/demo-link-dark.png" alt="Demo link in input (dark)" width="200" />
      </a>
      <br />
      <sub>Demo Link In Input (Dark)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/downloading-process-dark.png">
        <img src="showcase/preview/downloading-process-dark.png" alt="Downloading process (dark)" width="200" />
      </a>
      <br />
      <sub>Downloading Process (Dark)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/video-menu-opened-dark.png">
        <img src="showcase/preview/video-menu-opened-dark.png" alt="Video menu opened (dark)" width="200" />
      </a>
      <br />
      <sub>Video Menu Opened (Dark)</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <a href="showcase/high/video-export-opened-dark.png">
        <img src="showcase/preview/video-export-opened-dark.png" alt="Video export submenu opened (dark)" width="200" />
      </a>
      <br />
      <sub>Export Menu Opened (Dark)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/rename-file-dark.png">
        <img src="showcase/preview/rename-file-dark.png" alt="Rename file modal (dark)" width="200" />
      </a>
      <br />
      <sub>Rename File (Dark)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/vault-unlock-modal-dark.png">
        <img src="showcase/preview/vault-unlock-modal-dark.png" alt="Vault unlock modal (dark)" width="200" />
      </a>
      <br />
      <sub>Vault Unlock Modal (Dark)</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <a href="showcase/high/vault-unlocked-videos-dark.png">
        <img src="showcase/preview/vault-unlocked-videos-dark.png" alt="Unlocked vault with videos (dark)" width="200" />
      </a>
      <br />
      <sub>Vault Unlocked (Dark)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/paywall-window.png">
        <img src="showcase/preview/paywall-window.png" alt="Paywall (light)" width="200" />
      </a>
      <br />
      <sub>Paywall (Light)</sub>
    </td>
    <td align="center">
      <a href="showcase/high/paywall-window-dark.png">
        <img src="showcase/preview/paywall-window-dark.png" alt="Paywall (dark)" width="200" />
      </a>
      <br />
      <sub>Paywall (Dark)</sub>
    </td>
  </tr>
</table>
