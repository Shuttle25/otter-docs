# UI polish: clearer delivery ticks, no sender line in Otter news, Settings without section headers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two owner requests (2026-11-15): (1) delivery ticks with real contrast, design **B "ink, then a teal badge"**
chosen from three mock-ups; (2) news messages lose the «Выдра» / "Otter" line at the top of each bubble;
(3) owner 2026-11-16: Settings shows only its rows, without the section headers («Профиль», «Семья», «Медиа»,
«Уведомления», «Безопасность», «Подключение») — "no need for captions, just menu items".

**Architecture:** `DeliveryStatusIcon` (core/ui) gets the ink colour from its caller and draws READ as a filled teal
circle with cut-out ticks; `MessageMeta` passes its time colour and a photo flag. `NewsBubble` drops one `Text`.
`SettingsRoute` drops its `Section(...)` headers.
App only; no server, no proto, no database change.

**Tech Stack:** Kotlin, Jetpack Compose (Material 3), Robolectric Compose tests, JVM contrast test.

**Ships with:** the next app release after 0.9.1 (M9.2 shipped 0.9.1 without it; now M9.3). No version bump in this plan.

---

## Design B (owner's choice)

| State | Look (in a bubble / chat list) | On a photo (dark scrim) |
|---|---|---|
| PENDING | clock in the ink colour | white clock |
| SENT | ✓ in the ink colour | white ✓ |
| DELIVERED | ✓✓ in the ink colour | white ✓✓ |
| READ | 16 dp filled circle in `primary` with 12 dp ✓✓ in `onPrimary` | circle in the dark palette's `primary` (#83D5C4) with ✓✓ in its `onPrimary` (#00382F), both themes |
| FAILED | error icon in `error` (unchanged) | unchanged |

Ink = the colour of the time next to it: `onOutgoingContainer` in outgoing bubbles (10.8 : 1 light, 9.1 : 1 dark on
the bubble), `onSurface` in the chat list. Today SENT/DELIVERED use `onSurfaceVariant` (grey), which is nearly as
dark as the READ teal (1.1 : 1 between them), and on photos the ticks stay grey on the dark scrim while the time is white.
READ now differs by shape (filled circle), not only by colour (guide §8: never colour-only).

## Facts verified in the code (otter-android main, 2026-11-15, app 0.9.0)

| Question | Answer | Source |
|---|---|---|
| Tick drawing | `DeliveryStatusIcon(status, modifier)`; SENT/DELIVERED tint `onSurfaceVariant`, READ `primary` | `core/ui/src/main/kotlin/app/ottermsg/core/ui/components/DeliveryStatusIcon.kt` |
| Callers | `MessageMeta` (conversation) and `ChatListScreen.kt:124` | `git grep "DeliveryStatusIcon("` |
| Meta colours | photo overlay: `MessageMeta(time, status, color = Color.White)`; text under photo / plain bubble: `onContainer` for outgoing | `feature/conversation/.../MessageBubble.kt:110-134` |
| News header | `if (firstInGroup) Text(sender, …)` inside the bubble; `sender` also used in the TalkBack description and by `MessageNotifier` | `feature/conversation/.../NewsBubble.kt:88,118-121`; `app/.../notify/MessageNotifier.kt:64` |
| Palette | `OtterPalette.Light/Dark` raw ARGB longs; `ContrastTest` checks text pairs ≥ 4.5 | `core/ui/.../theme/Color.kt`, `core/ui/src/test/.../theme/ContrastTest.kt` |

## Branches and commits

The normal `otter-android` and `docs` trees may be in use by another session. Work in worktrees:
```bash
cd ~/Documents/Projects/OttterMSG
git -C otter-android fetch origin && git -C otter-android worktree add ../otter-android-ui -b ui-ticks-news origin/main
git -C docs fetch origin && git -C docs worktree add ../docs-ui -b ui-ticks-news origin/main
```
Commit with the `oc` function from the M9 plan header (UTC 12:00:SS dates, D57); every message ends with
`-m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`; never a `Claude-Session:` line.
Env: `export JAVA_HOME=~/.gradle/jdks/eclipse_adoptium-21-amd64-linux.2`.

---

### Task 1: Delivery ticks, design B

**Goal:** Ticks use the ink colour of their row, white on photos, and READ is a filled teal badge.

**Files:**
- Modify: `otter-android/core/ui/src/main/kotlin/app/ottermsg/core/ui/components/DeliveryStatusIcon.kt`
- Modify: `otter-android/feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/MessageMeta.kt`
- Modify: `otter-android/feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/MessageBubble.kt` (photo overlay call, ~line 120)
- Test: `otter-android/feature/conversation/src/test/kotlin/app/ottermsg/feature/conversation/MessageBubbleTest.kt`
- Test: `otter-android/core/ui/src/test/kotlin/app/ottermsg/core/ui/theme/ContrastTest.kt`

**Acceptance Criteria:**
- [ ] An outgoing READ message shows a node tagged `delivery-read-badge` whose description is «Прочитано»; DELIVERED shows none.
- [ ] The bubble's merged TalkBack description still contains «Прочитано» / «Доставлено» (existing test stays green).
- [ ] `ContrastTest`: ink on the outgoing bubble ≥ 4.5 and the badge (`primary`) against the outgoing bubble and the surface ≥ 3.0 (non-text UI), both themes.
- [ ] Chat list row shows the same ticks (ink = `onSurface`).

**Verify:** `cd ~/Documents/Projects/OttterMSG/otter-android-ui && ./gradlew :core:ui:testDebugUnitTest :feature:conversation:testDebugUnitTest :feature:chats:testDebugUnitTest` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing tests.** Add to `MessageBubbleTest` (imports: `androidx.compose.ui.test.onNodeWithTag`,
  `androidx.compose.ui.test.assertContentDescriptionEquals`, `app.ottermsg.core.ui.components.READ_BADGE_TAG`):

```kotlin
    @Test fun readIsABadgeDeliveredIsNot() {
        val read = MessageUi(1, outgoing = true, text = "Привет", sentMs = 0, status = DeliveryStatus.READ, system = false, authorName = "")
        compose.setContent { OtterTheme { MessageBubble(read, firstInGroup = true) } }
        compose.onNodeWithTag(READ_BADGE_TAG, useUnmergedTree = true).assertExists()
            .assertContentDescriptionEquals("Прочитано")
    }

    @Test fun deliveredHasNoBadge() {
        val m = MessageUi(2, outgoing = true, text = "Привет", sentMs = 0, status = DeliveryStatus.DELIVERED, system = false, authorName = "")
        compose.setContent { OtterTheme { MessageBubble(m, firstInGroup = true) } }
        compose.onNodeWithTag(READ_BADGE_TAG, useUnmergedTree = true).assertDoesNotExist()
    }
```

  In `ContrastTest` add:

```kotlin
    @Test fun ticksAndReadBadgeAreVisible() {
        for (t in listOf(OtterPalette.Light, OtterPalette.Dark)) {
            assertTrue("ink/outgoing", ratio(t.onOutgoingContainer, t.outgoingContainer) >= 4.5)
            assertTrue("ink/surface", ratio(t.onSurface, t.surface) >= 4.5)
            assertTrue("badge/outgoing", ratio(t.primary, t.outgoingContainer) >= 3.0)
            assertTrue("badge/surface", ratio(t.primary, t.surface) >= 3.0)
            assertTrue("badge ticks", ratio(t.onPrimary, t.primary) >= 3.0)
        }
        // the photo badge uses the dark pair on a ~45 % black scrim in both themes
        assertTrue("photo badge ticks", ratio(OtterPalette.Dark.onPrimary, OtterPalette.Dark.primary) >= 3.0)
    }
```

- [ ] **Step 2: Run — fails.** `./gradlew :feature:conversation:testDebugUnitTest --tests '*MessageBubbleTest*'` →
  compile error `Unresolved reference: READ_BADGE_TAG`. (`ContrastTest` already passes with today's palette: it guards
  the new design against later palette changes.)

- [ ] **Step 3: Implement** — replace the body of `DeliveryStatusIcon.kt` below the `DeliveryStatus` object:

```kotlin
/** Test tag of the READ badge. */
const val READ_BADGE_TAG = "delivery-read-badge"

/**
 * Guide §8, design B (owner, 2026-11-15): clock / ✓ / ✓✓ in [ink] (the colour of the time next to them), READ = ✓✓
 * cut out of a filled teal circle (shape, not colour only), error in red. [onPhoto]: on the dark photo scrim, white
 * ticks and the dark palette's badge in both themes. Never colour-only: each has a description.
 */
@Composable
fun DeliveryStatusIcon(
    status: Int,
    modifier: Modifier = Modifier,
    ink: Color = MaterialTheme.colorScheme.onSurface,
    onPhoto: Boolean = false,
) {
    val label = stringResource(deliveryStatusLabel(status))
    if (status == DeliveryStatus.READ) {
        val bg = if (onPhoto) Color(OtterPalette.Dark.primary) else MaterialTheme.colorScheme.primary
        val fg = if (onPhoto) Color(OtterPalette.Dark.onPrimary) else MaterialTheme.colorScheme.onPrimary
        Box(
            modifier.size(16.dp).background(bg, CircleShape).testTag(READ_BADGE_TAG)
                .semantics { contentDescription = label },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Outlined.DoneAll, contentDescription = null, tint = fg, modifier = Modifier.size(12.dp)) }
        return
    }
    val icon = when (status) {
        DeliveryStatus.PENDING -> Icons.Outlined.Schedule
        DeliveryStatus.SENT -> Icons.Outlined.Done
        DeliveryStatus.DELIVERED -> Icons.Outlined.DoneAll
        else -> Icons.Outlined.ErrorOutline
    }
    val tint = when {
        icon == Icons.Outlined.ErrorOutline -> MaterialTheme.colorScheme.error
        onPhoto -> Color.White
        else -> ink
    }
    Icon(icon, contentDescription = label, tint = tint, modifier = modifier.size(16.dp))
}
```

  New imports: `androidx.compose.foundation.background`, `androidx.compose.foundation.layout.Box`,
  `androidx.compose.foundation.shape.CircleShape`, `androidx.compose.ui.Alignment`,
  `androidx.compose.ui.graphics.Color`, `androidx.compose.ui.platform.testTag`,
  `androidx.compose.ui.semantics.contentDescription`, `androidx.compose.ui.semantics.semantics`,
  `app.ottermsg.core.ui.theme.OtterPalette`. `deliveryStatusLabel` stays as it is.

  `MessageMeta.kt`:

```kotlin
/** Time and (for outgoing) status in their own row under the text — never drawn over it (guide §7). The ticks take
 *  the time's colour; [onPhoto] = on the dark photo scrim (design B). */
@Composable
fun MessageMeta(time: String, status: Int?, color: Color, modifier: Modifier = Modifier, onPhoto: Boolean = false) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(Dimens.s4), verticalAlignment = Alignment.CenterVertically) {
        Text(time, style = MaterialTheme.typography.bodySmall, color = color)
        if (status != null) DeliveryStatusIcon(status, ink = color, onPhoto = onPhoto)
    }
}
```

  `MessageBubble.kt` photo overlay: `MessageMeta(time, status, color = Color.White)` → `MessageMeta(time, status, color = Color.White, onPhoto = true)`.
  `ChatListScreen.kt:124` keeps `DeliveryStatusIcon(row.status)` (default ink `onSurface`).

- [ ] **Step 4: Run** the Verify command → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add core/ui/src/main/kotlin/app/ottermsg/core/ui/components/DeliveryStatusIcon.kt \
  feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/MessageMeta.kt \
  feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/MessageBubble.kt \
  feature/conversation/src/test/kotlin/app/ottermsg/feature/conversation/MessageBubbleTest.kt \
  core/ui/src/test/kotlin/app/ottermsg/core/ui/theme/ContrastTest.kt
oc -m "ui: delivery ticks in the text colour, read = teal badge, white on photos (owner design B)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Otter news without the sender line

**Goal:** A news bubble starts with its text; «Выдра» stays in the TalkBack description and in notifications.

**Files:**
- Modify: `otter-android/feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/NewsBubble.kt` (~lines 118-121 and the KDoc above `NewsBubble`)
- Test: `otter-android/feature/conversation/src/test/kotlin/app/ottermsg/feature/conversation/NewsBubbleTest.kt`

**Acceptance Criteria:**
- [ ] No visible «Выдра» text in a news bubble, also for the first message of a group.
- [ ] The bubble's description still reads «Выдра, <text>, <time>».
- [ ] Spacing between news bubbles unchanged (`firstInGroup` still sets the top gap).

**Verify:** `./gradlew :feature:conversation:testDebugUnitTest --tests '*NewsBubbleTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** in `NewsBubbleTest` (imports `androidx.compose.ui.test.onAllNodesWithText`,
  `androidx.compose.ui.test.assertCountEquals`):

```kotlin
    @Test fun noSenderLineButTalkBackKeepsIt() {
        val m = MessageUi(1, outgoing = false, text = "Otter 0.9.1: новые галочки", sentMs = 0, status = MessageStatus.DELIVERED,
            system = false, authorName = "Выдра")
        compose.setContent { OtterTheme { NewsBubble(m, m.text, firstInGroup = true) } }
        compose.onAllNodesWithText("Выдра", useUnmergedTree = true).assertCountEquals(0)
        compose.onNode(SemanticsMatcher("description keeps the sender") { n ->
            n.config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString().orEmpty().startsWith("Выдра, Otter 0.9.1")
        }, useUnmergedTree = true).assertExists()
    }
```
  (also import `androidx.compose.ui.semantics.getOrNull` if missing.)

- [ ] **Step 2: Run — fails:** `expected 0 but found 1` for «Выдра».

- [ ] **Step 3: Implement.** In `NewsBubble.kt` delete:

```kotlin
                        if (firstInGroup) Text(sender, style = AuthorStyle, color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.clearAndSetSemantics {})
```
  Keep `val sender = stringResource(R.string.news_sender)` (TalkBack description). If `AuthorStyle` has no other use
  in the file, delete it too (`grep -n AuthorStyle NewsBubble.kt`). In the KDoc change "TalkBack: the bubble reads
  sender, text and time" to "No visible sender line (the chat is «Новости Otter»; owner 2026-11-15). TalkBack: the
  bubble still reads sender, text and time".
  Keep both `news_sender` strings: `MessageNotifier` uses the app module's copy.

- [ ] **Step 4: Run** the Verify command, then the whole module: `./gradlew :feature:conversation:testDebugUnitTest` → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add feature/conversation/src/main/kotlin/app/ottermsg/feature/conversation/NewsBubble.kt \
  feature/conversation/src/test/kotlin/app/ottermsg/feature/conversation/NewsBubbleTest.kt
oc -m "news: no «Выдра» line above each news message (owner); TalkBack keeps the sender" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Settings without section headers

**Goal:** The Settings screen is a plain list of rows; the six section headers are gone.

**Files:**
- Modify: `otter-android/feature/settings/src/main/kotlin/app/ottermsg/feature/settings/SettingsScreen.kt` (the `Section(...)` calls in `SettingsRoute`, `private fun Section` at ~line 176, imports `androidx.compose.ui.semantics.heading` and `androidx.compose.ui.semantics.semantics`)
- Modify: `otter-android/feature/settings/src/main/res/values/strings.xml`, `.../values-en/strings.xml` (delete `settings_profile`, `settings_family`, `settings_media`, `settings_notifications_section`, `settings_security`, `settings_connection`)
- Create: `otter-android/feature/settings/src/test/kotlin/app/ottermsg/feature/settings/SettingsScreenTest.kt`

**Acceptance Criteria:**
- [ ] No «Профиль», «Семья», «Медиа», «Безопасность», «Подключение» text on the Settings screen; «Уведомления» appears once (the row).
- [ ] Every row is still there in the same order: profile row, «Пригласить в семью», «Фото и память», «Уведомления», «Резервная копия», connection status, «Звонки только через сервер» (its explanation line stays: it says what the switch does), the full-screen-ringing fix when needed, «Журнал подключений», version footer.
- [ ] The first row keeps a top gap (`Dimens.s8`) under the top bar.
- [ ] No unused string resources left (`./gradlew :feature:settings:lint` has no new `UnusedResources`).

**Verify:** `./gradlew :feature:settings:testDebugUnitTest --tests '*SettingsScreenTest*'` → `BUILD SUCCESSFUL`

**Steps:**

- [ ] **Step 1: Failing test** `SettingsScreenTest.kt`:

```kotlin
package app.ottermsg.feature.settings

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import app.ottermsg.core.network.ConnectionState
import app.ottermsg.core.ui.theme.OtterTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "ru")
class SettingsScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun onlyRowsNoSectionHeaders() {
        val vm = SettingsViewModel(MutableStateFlow(null), MutableStateFlow(ConnectionState.Connecting), emptyFlow(), {})
        compose.setContent { OtterTheme { SettingsRoute(onBack = {}, onInvite = {}, onProfile = {}, vm = vm) } }
        for (header in listOf("Профиль", "Семья", "Медиа", "Безопасность", "Подключение"))
            compose.onNodeWithText(header).assertDoesNotExist()
        compose.onAllNodesWithText("Уведомления").assertCountEquals(1)
        for (row in listOf("Пригласить в семью", "Фото и память", "Резервная копия", "Подключаемся…", "Журнал подключений"))
            compose.onNodeWithText(row).assertExists()
    }
}
```

- [ ] **Step 2: Run — fails:** `Failed: assertDoesNotExist` for «Семья» (the first header found).

- [ ] **Step 3: Implement.** In `SettingsRoute` delete the six lines `Section(stringResource(R.string.settings_…))`
  and put `Spacer(Modifier.heightIn(min = Dimens.s8))` as the first child of the `Column` (`Spacer`, `heightIn` are
  already imported). Delete `private fun Section(title: String)` with its KDoc, and the now unused imports
  `androidx.compose.ui.semantics.heading` and `androidx.compose.ui.semantics.semantics` (check with
  `grep -n "semantics\|heading" SettingsScreen.kt`; `Role` stays). Change the KDoc of `SettingsRoute` to
  "Settings: one plain list of rows, no section headers (owner 2026-11-16)." Delete the six strings in both
  `values/strings.xml` and `values-en/strings.xml`; first check nothing else uses them:
  `git grep -n "settings_profile\b\|settings_family\b\|settings_media\b\|settings_notifications_section\|settings_security\b\|settings_connection\b"`
  must list only the lines being deleted. (`settings_profile_*` strings with longer names stay.)

- [ ] **Step 4: Run** the Verify command, then `./gradlew :feature:settings:testDebugUnitTest :feature:settings:lint` → `BUILD SUCCESSFUL`.

- [ ] **Step 5: Commit**

```bash
git add feature/settings/src/main/kotlin/app/ottermsg/feature/settings/SettingsScreen.kt \
  feature/settings/src/main/res/values/strings.xml feature/settings/src/main/res/values-en/strings.xml \
  feature/settings/src/test/kotlin/app/ottermsg/feature/settings/SettingsScreenTest.kt
oc -m "settings: plain list of rows, no section headers (owner)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Later milestones:** new Settings rows (M9.4 «Сеть», M9.5 «Показывать меня в каталоге сети», M10 «Экономить
трафик в видеозвонках») are added as plain rows in this list, without headers.

---

### Task 4: Design guide, checks, merge

**Goal:** The guide matches the app, all checks pass, the owner sees it on a phone before merging.

**Files:**
- Modify: `docs-ui/10-otter-design-guidelines.md` (§8 table rows SENT / DELIVERED / READ; one sentence in the news part of §7 or §11 where news bubbles are described — `grep -n -i "новост" 10-otter-design-guidelines.md`)

**Acceptance Criteria:**
- [ ] §8 rows say: SENT «Одна галочка цвета текста», DELIVERED «Две галочки цвета текста», READ «Две галочки в залитом бирюзовом круге (отличается формой, не только цветом)»; plus «На фото: белые галочки, бирюзовый круг тёмной темы».
- [ ] The guide says news messages have no sender line.
- [ ] §10 says: «Экран настроек — один список строк без заголовков разделов (владелец, 2026-11-16); таблица ниже
  описывает группы строк, а не видимые заголовки».
- [ ] `./gradlew lint testDebugUnitTest` green; `scripts/secrets-check.sh` ok in `otter-android-ui` and `docs-ui`.
- [ ] Merged `--no-ff` only after the owner's OK.

**Verify:** `cd ~/Documents/Projects/OttterMSG/otter-android-ui && ./gradlew lint testDebugUnitTest && scripts/secrets-check.sh` → `BUILD SUCCESSFUL`, `secrets check: ok`

**Steps:**

- [ ] **Step 1:** Edit the guide as in the criteria; commit in `docs-ui`:
  `oc -m "guide: delivery ticks design B, news without a sender line, settings without section headers" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`.
- [ ] **Step 2:** Run the Verify command and `scripts/secrets-check.sh` in `docs-ui`.
- [ ] **Step 3: Ask the owner → look on a phone or the emulator** (debug build from `otter-android-ui`): a chat with
  sent, delivered and read messages, a photo without a caption, the chat list, light and dark theme, the news chat,
  and Settings without headers.
- [ ] **Step 4: Ask the owner → merge** (through temporary worktrees, so busy trees stay untouched):

```bash
cd ~/Documents/Projects/OttterMSG
for r in otter-android docs; do
  git -C $r fetch origin && git -C $r worktree add ../$r-merge origin/main --detach
  (cd $r-merge && git merge --no-ff --no-commit ui-ticks-news && oc -m "Merge UI polish: delivery ticks design B, news without sender line, settings without headers" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && scripts/secrets-check.sh && git push origin HEAD:main)
  git -C $r worktree remove ../$r-merge
done
git -C otter-android worktree remove ../otter-android-ui && git -C docs worktree remove ../docs-ui
```
  If an M9.3 branch already exists, tell its session: "merge origin/main into the M9.3 branch" (the change then ships with M9.3).
