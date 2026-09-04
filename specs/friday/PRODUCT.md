# Friday PRODUCT

## Summary

Friday is a macOS-only Apple Silicon menu-bar dictation instrument for fast, private speech-to-text in the app the user was already using. It captures the complete utterance from deliberate hotkey-down, transcribes with one local ASR model, gives immediate and truthful feedback, and pastes or copies only authoritative final text. Friday is the speech-input layer; it does not interpret commands, conduct conversations, or route work to an agent runtime.

## Goals / Non-goals

- Goal: provide reliable global press-and-hold dictation into the source app with a compact nonactivating overlay.
- Goal: keep the default model local, downloadable, cancellable, retryable, integrity-checked, and manageable on disk.
- Goal: make permission, model, recording, transcription, paste, and fallback states explicit and recoverable.
- Goal: capture speech from hotkey-down without clipping the leading phoneme while silently discarding accidental short taps.
- Goal: decode incrementally when and only when the selected local model genuinely supports streaming, with a stable-prefix/mutable-tail preview and final-only insertion.
- Goal: qualify model and recognition behavior with reproducible quality, latency, memory, energy, privacy, and long-session evidence.
- Non-goal: cloud ASR is not part of Friday.
- Non-goal: partial text is never pasted, copied, persisted, added to diagnostics, or presented as final.
- Non-goal: transcript history is not part of Friday.
- Non-goal: text transforms, rewriting, summaries, templates, commands, conversations, tool routing, or OpenCode configuration are not part of Friday.
- Non-goal: media pause, system mute, meeting-app mute, or audio ducking is not part of Friday.
- Non-goal: iOS, iPadOS, Windows, Linux, web, or Intel Mac support is not part of the current product.
- Non-goal: multiple simultaneous recordings are not part of Friday.

## Figma

Figma: none provided

## Behavior

1. Friday runs only on Apple Silicon Macs.

2. When Friday is opened on an unsupported platform, it shows a clear unsupported-platform message and does not present onboarding steps that cannot succeed.

3. Friday appears as a menu-bar app by default.

4. Friday does not require a Dock window to remain open for dictation to work.

5. Friday can show a settings window when the user chooses settings from the menu-bar menu.

6. Friday can complete dictation while the settings window is closed.

7. Friday never sends microphone audio, transcripts, model files, or model identifiers to a cloud ASR service.

8. Friday may contact the network only for user-visible model discovery or model download actions.

9. Friday treats the app that had keyboard focus when recording started as the source app for that dictation session.

10. Friday never starts more than one recording at a time.

11. If the user attempts to start recording while another recording is active, Friday keeps the existing recording active and gives visible feedback that recording is already in progress.

12. If the user presses the configured hotkey while transcription is active for a previous recording, Friday cancels and invalidates the previous session, starts a fresh recording immediately, and treats any late result from the previous session as stale.

13. First launch opens onboarding before normal settings.

14. Onboarding explains, in user-facing language, that Friday needs Microphone permission to record speech.

15. Onboarding explains, in user-facing language, that Friday needs Accessibility permission to paste into the source app.

16. Onboarding explains, in user-facing language, that Friday needs Input Monitoring permission to detect the global dictation hotkey while another app is focused.

17. Onboarding shows the current grant state for Microphone, Accessibility, and Input Monitoring separately.

18. Onboarding provides a direct action for each permission that is not granted.

19. Onboarding does not claim a permission is granted until Friday can observe that the permission is usable.

20. If the user denies Microphone permission, Friday cannot enter recording state and shows the Microphone permission recovery action wherever recording would otherwise start.

21. If the user denies Input Monitoring permission, Friday cannot use the global hotkey and shows the Input Monitoring recovery action wherever global hotkey controls appear.

22. If the user denies Accessibility permission, Friday can still record and transcribe when started from Friday, but it cannot paste into the source app; completed transcripts use the clipboard fallback.

23. Onboarding may be completed in limited mode only after the user has explicitly acknowledged which missing permissions will disable which behaviors.

24. When all three permissions are granted, onboarding marks permissions complete without requiring the user to restart Friday.

25. Onboarding includes default model setup before Friday reports itself ready for dictation.

26. Parakeet TDT v3 remains the default until a candidate defeats it on Friday's exact capture/runtime path and satisfies quality, latency, memory, energy, privacy, and distribution-license gates.

27. If the default Parakeet TDT v3 model is not already available locally, Friday offers to download it during onboarding.

28. If the default model download is required for first use, Friday starts that download automatically unless the user cancels it.

29. While a model is downloading, Friday shows the model name, total progress when known, downloaded amount when known, current state, and a Cancel action.

30. The user can cancel a model download without corrupting an already usable model.

31. After a canceled model download, Friday shows Retry and Choose Local Model actions.

32. If Friday is offline before the default model is available, onboarding explains that local transcription is unavailable until a compatible model is downloaded or selected locally.

33. If Friday is offline and a compatible local model is already selected, recording and transcription remain available.

34. Friday verifies downloaded model integrity before making the model selectable.

35. If model integrity verification fails, Friday does not use the failed model, labels the download as failed, and offers Retry and Remove Failed Download actions.

36. Friday does not silently redownload a failed model in a loop.

37. Friday resumes or retries model downloads only after a user-visible retry action or a normal app relaunch that clearly shows the pending download state.

38. Friday allows the user to add a local model from disk only when its complete manifest identity exactly matches a Friday-reviewed production allowlist entry and its bytes match that entry’s size and SHA-256 before parser access.

39. Friday allows the user to inspect bounded public Hugging Face metadata by identifier. It downloads or adds a model only when the resolved immutable revision, artifact, byte count, and SHA-256 exactly match a Friday-reviewed production allowlist entry.

40. Friday does not present arbitrary local files or arbitrary Hugging Face repositories as compatible ASR models and never sends their GGUF bytes to the in-process parser or recognizer.

41. A model is selectable only when its immutable manifest identity is on Friday’s production allowlist, its bytes pass exact integrity checks, and its declared capabilities pass the corresponding local runtime probe; streaming, language, punctuation, vocabulary, and quality capabilities remain separate evidence.

42. If a local or Hugging Face model is not allowlisted or fails integrity/runtime verification, Friday states why it is unavailable and does not make it active.

43. Friday distinguishes the selected model from available but inactive models.

44. Friday allows the user to switch the active model when no recording or transcription is in progress.

45. Friday does not switch the active model in the middle of an active recording or transcription.

46. If the user requests a model switch during an active session, Friday asks the user to wait or cancel the active session first.

47. Friday allows the user to remove a model from Friday’s model list.

48. Removing a local model that Friday did not download only removes Friday’s reference to that model; it does not delete the original file unless the user is explicitly told that deletion will occur and confirms it.

49. Removing a model downloaded by Friday offers a clear choice to keep the files on disk or delete Friday’s downloaded copy.

50. If the active model is removed, Friday becomes not ready until another compatible model is selected or downloaded.

51. Friday shows model disk usage for each model when known.

52. Friday shows total Friday-managed model disk usage when known.

53. Friday offers a way to delete failed, partial, or unused Friday-managed model downloads.

54. Friday never deletes user-selected local model files as part of automatic cleanup.

55. Friday’s global dictation hotkey is configurable by the user.

56. Friday does not enable global dictation until the user has chosen or confirmed a hotkey.

57. Friday warns the user when the chosen hotkey cannot be captured globally.

58. Friday warns the user when the chosen hotkey appears to conflict with a system-reserved shortcut or cannot be reliably distinguished.

58a. Friday supports the Mac Fn/Globe key by itself as a global dictation shortcut and records it when the user presses and releases it.

58b. After setup, clicking Friday's menu-bar item opens its menu without opening the main window; the menu provides an explicit Open Friday action.

58c. The recording capsule replaces active-session content with a concise terminal outcome before dismissing: pasted for 600–800 ms, copied for 2.5–3 seconds, no speech for 1.5–2 seconds, and failure for 3–4 seconds or until its required recovery action is visible elsewhere. It never displays transcript text.

59. Friday supports press-and-hold recording for the configured hotkey.

60. In press-and-hold mode, provisional recording starts on accepted hotkey-down. Crossing the configured hold threshold commits that same uninterrupted capture; release below the threshold stops and deletes it without transcription.

61. In press-and-hold mode, recording stops when the user releases the configured hotkey.

62. Friday supports double-tap-lock recording for the configured hotkey.

63. In double-tap-lock mode, two presses of the configured hotkey within the configured double-tap window toggle locked recording on.

64. While locked recording is on, the user does not need to keep holding the hotkey.

65. While locked recording is on, pressing the configured hotkey again stops recording.

66. If Friday cannot determine whether the user intended press-and-hold or double-tap-lock, it prefers not to start a locked recording accidentally.

67. Friday exposes the double-tap-lock behavior as enabled by default or disabled by user setting.

68. Friday lets the user adjust the double-tap timing window within a safe range.

69. Friday provides a visible recording indicator whenever microphone recording is active.

70. Friday provides a compact overlay during recording.

71. The overlay does not activate Friday or steal keyboard focus from the source app.

72. The overlay shows at least recording state and elapsed recording time.

73. The overlay shows a stop affordance when recording is locked.

74. The overlay shows a cancel affordance while recording is active.

75. The overlay remains compact enough not to obscure the source app’s primary content by default.

76. The overlay can be moved or dismissed according to user preference without canceling recording unless the user chooses Cancel.

77. Friday respects reduced-motion settings by avoiding nonessential animation in the overlay and status transitions.

78. Friday shows live partial transcript text only when the active model and runtime have passed a genuine streaming capability probe. Friday never simulates streaming by repeatedly decoding growing prefixes with a final-only model.

79. Streaming preview uses a stable committed prefix and a visually distinct mutable tail. Revisions are scoped to session and generation; stale, canceled, or out-of-order revisions are ignored.

80. When recording stops normally, Friday transitions from recording to transcribing.

81. During recording or finalization, Friday may show streaming preview in the capsule, but only the authoritative final result may enter delivery. Final-only models show recording/transcribing state without partial text.

82. During transcription, Friday provides a Cancel action.

83. If the user cancels during recording, Friday stops recording and discards the audio for that session.

84. If the user cancels during transcription, Friday invalidates that session immediately and does not paste or copy any result from it.

85. If a transcript result arrives after the user canceled that session, Friday treats it as stale and does not paste, copy, show as current, or save it.

86. If a transcript result arrives for any session other than the most recently active uncanceled session, Friday treats it as stale.

87. Friday never pastes text from a stale session.

88. Friday never copies text from a stale session as the automatic result of dictation.

89. If transcription succeeds and Accessibility permission is available, Friday attempts to return focus to the source app and paste the final transcript.

90. Friday pastes only the final transcript for the completed session.

91. Friday does not paste intermediate, partial, empty, canceled, failed, or stale text.

92. If the source app is no longer available, no longer accepts text, or cannot be focused, Friday does not guess a new destination.

93. If source-app paste cannot be completed, Friday copies the final transcript to the clipboard and shows a clear fallback message.

94. If Accessibility permission is unavailable at paste time, Friday copies the final transcript to the clipboard and shows the Accessibility recovery action.

95. If clipboard fallback fails, Friday shows the final transcript in Friday and provides a manual Copy action.

96. Friday does not overwrite the clipboard before a final transcript exists unless the user explicitly chooses a copy action.

97. Friday makes it clear when the transcript was pasted versus copied to clipboard versus only shown in Friday.

98. Friday treats empty or silence-only recordings as no transcript.

99. For a silence-only recording, Friday does not paste or copy anything automatically.

100. For a silence-only recording, Friday shows a concise no-speech-detected message and returns to ready state.

101. Friday handles very short accidental recordings by stopping capture, deleting its audio, and producing no transcription, copy, paste, or error unless an explicit locked/manual session was started.

102. Friday handles long recordings by showing continued recording/transcribing state and a Cancel action.

103. Friday’s maximum recording duration is exactly 10 minutes.

104. At 9:45 of an active recording, Friday warns the user that recording will stop automatically at 10:00; at 10:00, Friday stops recording, transcribes the captured audio, and explains that the 10-minute limit was reached.

105. If microphone input becomes unavailable during recording, Friday stops the session, does not paste, and shows a recoverable microphone error.

106. If the selected model becomes unavailable before transcription starts, Friday does not paste or copy stale output and prompts the user to reselect or redownload a model.

107. If transcription fails, Friday shows the model name, a concise failure reason when available, and Retry, Copy Diagnostics, and Change Model actions when applicable.

108. Retrying a failed transcription uses only the audio from the failed session and never records additional audio silently.

109. If Friday no longer has the audio needed to retry, Retry is not shown.

110. If the user changes model after a failed transcription, Friday does not automatically retry until the user requests retry or records again.

111. Friday errors are written in user-facing language and avoid raw stack traces in primary UI.

112. Friday provides a copyable diagnostics detail view for support/debugging.

113. Diagnostics do not include microphone audio or transcript text unless the user explicitly chooses to include them.

114. Friday’s menu-bar icon indicates at least ready, recording, transcribing, error, and not-ready states.

115. The menu-bar menu provides Start Recording when Friday is ready and no recording is active.

116. The menu-bar menu provides Stop Recording when recording is active.

117. The menu-bar menu provides Cancel when recording or transcription is active.

118. The menu-bar menu provides Settings.

119. The menu-bar menu provides Models.

120. The menu-bar menu provides Access.

121. The menu-bar menu provides Launch at Login toggle.

122. The menu-bar menu provides Quit.

123. If Friday is not ready, the menu-bar menu shows the specific blocking reason: missing microphone permission, missing input monitoring permission for global hotkey, missing model, failed model download, or unsupported platform.

124. Controls, Models, and Access show the active hotkey, double-tap-lock setting, selected model, model storage summary, permission status, paste behavior, overlay preference, launch-at-login setting, and privacy statement.

125. Launch at Login is off until the user enables it or accepts it during onboarding.

126. If Launch at Login is enabled, Friday starts in the menu bar without opening the settings window unless attention is required.

127. If Friday launches at login and is not ready, it shows a nonintrusive attention state in the menu bar and does not interrupt the user with a modal prompt.

128. Friday is keyboard accessible.

129. Every interactive control in onboarding, Controls, Models, Access, menu, and overlay has an accessible name.

130. Friday supports keyboard navigation through onboarding and settings without requiring the mouse.

131. Friday never relies on color alone to distinguish ready, recording, transcribing, error, or disabled states.

132. Friday’s overlay and settings remain readable in light mode, dark mode, increased contrast, and reduced transparency modes.

133. Friday preserves enough state across relaunch to avoid repeating completed onboarding steps unnecessarily.

134. Friday rechecks permissions on launch because macOS permissions can change outside Friday.

135. If a previously granted permission is revoked while Friday is running, Friday reflects the revoked state before the next affected action.

136. If a permission is revoked during an active session, Friday stops or degrades only the behavior that depends on that permission and explains what happened.

137. Friday does not store transcript history.

138. After paste or clipboard fallback completes, Friday returns to ready state and does not retain a browsable list of previous transcripts.

139. Friday may show the most recent transcript only as the immediate result of the current session or until it is dismissed/replaced.

140. Friday does not record system audio.

141. Friday does not record from multiple microphones at once.

142. Friday does not allow multiple simultaneous active models for a single recording.

143. Friday does not transform, summarize, rewrite, translate, or format transcripts with user prompts. Any future deterministic inverse text normalization requires an explicit per-language product contract and user control.

144. Friday does not pause media, mute other apps, or change system audio state.

145. Friday does not expose cloud model sign-in, cloud API keys, or cloud fallback.

146. Friday does not imply that final-only Parakeet TDT v3 can produce live partial text and never labels a model streaming-capable until an installed-artifact runtime probe succeeds.

147. Friday’s privacy copy states that dictation is always local and that model downloads require network access.

148. Friday’s privacy copy states whether model identifiers or download requests may be visible to model hosting providers when the user downloads a Hugging Face model.

149. Friday asks before opening an external model page or starting a non-default Hugging Face model download.

150. Friday never starts recording in response to ordinary typing that is not the configured hotkey.

151. Friday never starts recording before the user has granted Microphone permission.

152. Friday never pastes text into an app unless the user initiated a dictation session and that session completed successfully.

153. Friday never hides a failed paste by claiming success.

154. Friday always gives the user a way back to ready state after cancelable errors, permission denials, failed downloads, failed transcription, failed paste, or unsupported model selection.

155. Friday presents one calm, native voice-instrument surface whose hierarchy remains clear in light, dark, high-contrast, and reduced-motion environments; color communicates live or exceptional state rather than decoration.

156. Friday offers Parakeet CTC 1.1B as a known repository shortcut for metadata inspection only. It remains unavailable for download, parsing, probing, selection, or recognition until a future Friday release adds an exact reviewed artifact to the production allowlist.

157. Friday begins accepted hotkey capture within the existing 75 ms p95 budget and retains speech that begins immediately after hotkey-down; it does not use an always-on or pre-keydown microphone buffer.

158. Friday treats an idle input-device change or wake as requiring capture-device revalidation before the next session. An active route loss, device removal, sleep, callback stall, or conversion failure stops capture, removes partial audio, and reports a generation-scoped recoverable interruption.

159. Friday treats zero-length and sub-minimum captures as no speech. Speech detection is qualified against quiet speech, sparse speech, impulses, fan/keyboard noise, and long recordings rather than a single whole-file energy threshold.

160. If the core/native event channel closes, rejects lifecycle traffic, or cannot deliver a terminal control event, Friday fails closed: the microphone stops, source capability and audio are discarded, and no transcript is delivered.

161. Friday distinguishes **Ready — global shortcut active** from **Ready — manual recording only**. A recording begun while Friday itself is frontmost is explicitly clipboard-only and never guesses the previously focused app.

162. The capsule announces recording, locked recording, transcribing, terminal copy/paste, and failures once through accessibility APIs without announcing timer or meter updates. Stop, Hide, and Cancel remain nonactivating and expose keyboard and VoiceOver actions.

163. A streaming model is opt-in until a hash-pinned exact-path corpus shows that its final quality is no worse than the current default beyond declared thresholds and its first-partial latency, revision stability, tail latency, memory, energy, privacy, and long-session behavior pass release gates.

164. Streaming ASR failure, unsupported capability, or bounded-queue saturation falls back to one local whole-file recognition of the authoritative retry audio. Friday never delivers an interim hypothesis as fallback final text.

165. Partial transcript events have the neutral contract `partial(sessionId, generation, revision, stablePrefix, mutableTail)`, `final(sessionId, generation, text)`, and `cancelled(sessionId, generation)`. They are local, ephemeral, generation-safe, and contain no Jarvis/OpenCode semantics.

166. Model quality claims are corpus-backed and capability-specific. Friday reports results by language/accent/noise slice and does not equate artifact size, repository labels, supported-language count, or successful runtime loading with transcription quality.

167. Delivery is generation-scoped and cancellable through every irreversible boundary. Starting or canceling a newer session prevents an older session from mutating another app, even if the old core result would later be ignored.

168. Every automatic insertion path verifies the captured process, launch identity, window, and editable element. If the original element cannot be restored and mutation cannot be proven against its before-state, Friday leaves final text on the clipboard instead of pasting into another field, tab, pane, or document in the same app.

169. Friday never automatically inserts into a secure text or password field. It uses a clearly identified manual clipboard fallback without first attempting a blind synthetic paste.

170. Clipboard preservation is transactional and bounded. Friday restores a complete supported snapshot only after confirmed insertion, never overwrites a newer user clipboard change, and reports restoration failure rather than claiming an unqualified paste success.
