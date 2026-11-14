# Saved replies (Vietnamese and English)

Owner: the maintainer. Specification: QA-R49, QA-R53, QA-R46, QA-R47, PLT-R1207.

How to use: copy a reply, fill the `<...>` fields, send it. Replace `{{AppName}}` with the display name from `scripts/brand.env`.

Rules for every reply:

- **Ask for the in-app report and the practice-field check first (QA-R49).** Do not ask end users for verbose logs or terminal commands as a first step. Developer-level instructions are a last resort, written step by step.
- Never ask users to paste typed text, passwords or private content. Ask them to retype a short example.
- A reply that says "turn on setting X" gets the label `resolution:setting-workaround` and opens a follow-up task: change the default, fix the behaviour, or improve the setting's explanation (QA-R48).
- Vietnamese is standard, neutral and addresses the user as "bạn" (PRD-R62). Pane names must match the user's macOS language and version; check them on a system in that language before using them (PRD-R64, VERIFY).
- A confirmed issue gets the labels in QA-R45; an issue is not closed when the fix merges (QA-R46).

Index:

1. [Report a bug (QA-R49 order)](#1-report-a-bug)
2. [Permission missing or stale](#2-permission)
3. [Secure Input (including iTerm2)](#3-secure-input)
4. [Another input method is running](#4-another-input-method)
5. [Known limitation](#5-known-limitation)
6. [Switch to the beta channel](#6-switch-to-beta)
7. [Lifecycle: fixed in beta, fixed in release, closing](#7-lifecycle)

---

## 1. Report a bug

Use when the report is thin, or the user has not used the in-app report. Order of asks (QA-R49): the in-app report, the practice field, then (only if still needed) a typing trace. Never logs or terminal commands first.

### Vietnamese

Cảm ơn bạn đã báo lỗi. Để mình tìm đúng nguyên nhân, bạn giúp mình hai việc nhỏ nhé:

1. Mở {{AppNameTM}} trên thanh menu, chọn **Báo lỗi...**, chọn ứng dụng đang bị lỗi và triệu chứng gần nhất, rồi bấm **Mở GitHub**. Ứng dụng sẽ chép sẵn phần chẩn đoán vào bộ nhớ tạm, bạn chỉ cần dán vào ô tương ứng. Phần chẩn đoán không chứa nội dung bạn đã gõ. Bạn có thể bấm **Xem trước dữ liệu sẽ gửi** để kiểm tra.
2. Trong cửa sổ báo lỗi, bấm **Thử trong ô gõ thử** rồi gõ lại đúng ví dụ bị lỗi. Cho mình biết lỗi có xảy ra ở ô gõ thử không. Nếu không, lỗi nằm ở ứng dụng cụ thể kia, và đó là thông tin rất hữu ích.

Bạn không cần gửi nhật ký hay chạy lệnh nào. Nếu sau hai bước này mình vẫn thiếu thông tin, mình sẽ hướng dẫn thêm từng bước. Bạn cũng có thể gửi báo cáo qua email nếu không có tài khoản GitHub (địa chỉ hỗ trợ có trên website).

### English

Thank you for the report. To find the cause, two small things would help:

1. Open {{AppNameTM}} from the menu bar, choose **Báo lỗi... (Report a problem)**, pick the app where it happens and the closest symptom, then click **Mở GitHub (Open GitHub)**. The app copies the diagnostics block to your clipboard; paste it into the matching field. The diagnostics contain no typed content, and **Xem trước dữ liệu sẽ gửi (Preview what will be sent)** shows exactly what is included.
2. In the report window, click the practice-field button and retype the example that goes wrong. Tell us whether it also goes wrong there. If it does not, the problem is specific to that app, which is very useful to know.

You do not need to send logs or run commands. If we still need more after these two steps, we will explain the next step one at a time. If you do not have a GitHub account, you can send the report by email (the support address is on the website).

---

## 2. Permission

Use when the menu icon is slashed, the user says the app "does nothing", or typing stopped after a macOS update.

### Vietnamese

Có vẻ {{AppNameTM}} chưa có quyền nhận phím gõ, hoặc macOS đã tắt quyền này (thường xảy ra sau khi cập nhật hệ điều hành). Trong lúc đó {{AppName}} tự tạm dừng để bàn phím của bạn vẫn dùng bình thường. Bạn làm như sau:

1. Bấm vào biểu tượng {{AppName}} trên thanh menu. Dòng trạng thái ở đầu menu sẽ cho biết chính xác vấn đề, bấm vào đó để mở đúng chỗ cấp quyền.
2. Hoặc mở **Cài đặt hệ thống > Quyền riêng tư & Bảo mật > Trợ năng** (trên macOS 27 mục này có tên **Điều khiển thiết bị và truy cập dữ liệu**) và bật {{AppName}}.
3. Nếu {{AppName}} đã bật nhưng vẫn không gõ được: chọn {{AppName}} trong danh sách, bấm dấu trừ (-) để xóa, rồi thêm lại. Hoặc dùng nút **Đặt lại quyền** trong phần hướng dẫn của {{AppName}}, nút này chỉ đặt lại quyền của riêng {{AppName}}.
4. Hãy chắc rằng ứng dụng nằm trong thư mục **Ứng dụng** (/Applications), không chạy trực tiếp từ ổ DMG.

Cho mình biết kết quả nhé. Nếu vẫn chưa được, bạn gửi giúp mình báo cáo từ mục **Báo lỗi...**, không cần nhật ký.

### English

It looks like {{AppNameTM}} does not have permission to receive key presses, or macOS switched it off (this often happens after an OS update). While that is the case {{AppName}} pauses itself so your keyboard keeps working normally. Please:

1. Click the {{AppName}} icon in the menu bar. The status line at the top of the menu says exactly what is wrong; click it to open the right place.
2. Or open **System Settings > Privacy & Security > Accessibility** (on macOS 27 this pane is named **Device Control and Data Access**) and switch {{AppName}} on.
3. If it is already on but typing still does not work: select {{AppName}} in the list, click the minus (-) button to remove it, then add it again. Or use the **Reset permission** button in {{AppName}}'s guidance, which resets only {{AppName}}'s entry.
4. Make sure the app is in the **Applications** folder (/Applications) and not running directly from the DMG.

Let us know how it goes. If it still fails, send a report from **Report a problem...**; no logs needed.

Internal note: never advise `sudo tccutil reset Accessibility` without a bundle ID, because it resets every app (PLT-R741). The in-app button runs the reset scoped to this app.

---

## 3. Secure Input

Use when the report says typing is blocked "at random", especially in iTerm2 or a terminal, or the menu shows a lock badge.

Facts for the maintainer: while any app holds secure input, macOS stops delivering keys to every keyboard tool (Apple TN2150), so no event-tap input method can work. {{AppName}} pauses only for the OS secure-input state or a real password field, never on guesses (PLT-R398A), and resumes on the first key after it is released (PLT-R398B). The menu names the likely holder, which can be wrong (PLT-R396). iTerm2 turns on secure keyboard entry by itself while it believes a password prompt is showing, in addition to its manual menu item (PLT-R398C).

### Vietnamese

Đây không phải lỗi của bộ gõ: khi một ứng dụng bật **chế độ nhập bảo mật** (Secure Input), macOS chặn phím với mọi bộ gõ, và {{AppNameTM}} tạm dừng cho đến khi chế độ đó tắt. Bạn làm như sau:

1. Bấm biểu tượng {{AppName}} trên thanh menu. Nếu có biểu tượng khóa, dòng trạng thái sẽ nêu ứng dụng nhiều khả năng đang giữ chế độ này (tên này không phải lúc nào cũng chính xác).
2. **Terminal:** tắt mục **Nhập dùng Bàn phím An Toàn (Secure Keyboard Entry)** trong menu Terminal.
3. **iTerm2:** tắt mục **iTerm2 > Secure Keyboard Entry**, hoặc nhập xong (hay hủy) lời nhắc mật khẩu đang chờ. iTerm2 còn tự bật chế độ này khi nó cho rằng đang có lời nhắc mật khẩu (ví dụ sau lệnh `sudo` hoặc `ssh`): nhập xong rồi nhấn Return, hoặc nhấn Control+C để hủy; chế độ bảo mật sẽ tự tắt và {{AppName}} gõ lại được ngay ở phím tiếp theo.
4. **Trình duyệt hoặc trình quản lý mật khẩu:** bấm ra ngoài ô mật khẩu, hoặc chuyển sang thẻ khác.
5. Nếu không xác định được ứng dụng nào đang giữ, hoặc menu chỉ ra `loginwindow`: khóa màn hình rồi mở khóa (Control+Command+Q), hoặc đăng xuất rồi đăng nhập lại.

{{AppName}} chỉ tạm dừng theo trạng thái của hệ điều hành hoặc khi ô đang gõ là ô mật khẩu thật sự, không bao giờ đoán.

### English

This is not an input method bug: when an app turns on **Secure Input**, macOS blocks keys for every input method, and {{AppNameTM}} pauses until it is off. Please:

1. Click the {{AppName}} icon in the menu bar. If it shows a lock badge, the status line names the app that most likely holds secure input (the name is not always accurate).
2. **Terminal:** in the Terminal menu, turn off **Secure Keyboard Entry**.
3. **iTerm2:** turn off **iTerm2 > Secure Keyboard Entry**, or finish or cancel the password prompt it is waiting for. iTerm2 also turns secure input on by itself while it believes a password prompt is showing (for example after `sudo` or `ssh`): finish the prompt with Return or cancel it with Control+C; secure input then releases and {{AppName}} types again from the very next key.
4. **Browser or password manager:** click outside the password field, or switch tabs.
5. If the holder cannot be identified, or the menu points to `loginwindow`: lock and unlock the screen (Control+Command+Q), or log out and in.

{{AppName}} pauses only on the operating system's state or a real password field, and never guesses.

---

## 4. Another input method

Use when letters are doubled or swallowed, or the menu or onboarding reports a conflict.

### Vietnamese

Hai bộ gõ chạy cùng lúc sẽ làm lặp hoặc mất chữ. Có vẻ máy bạn đang chạy {{OtherApp}} (hoặc nguồn nhập tiếng Việt có sẵn của macOS). Bạn thử như sau:

1. Thoát {{OtherApp}} (bấm biểu tượng trên thanh menu và chọn Thoát), rồi tắt tùy chọn tự mở khi đăng nhập của nó. {{AppNameTM}} không tự thoát hay chỉnh sửa ứng dụng khác của bạn.
2. Nếu bạn dùng nguồn nhập **Tiếng Việt** có sẵn của macOS: mở **Cài đặt hệ thống > Bàn phím > Nguồn nhập** và chọn bàn phím **ABC** hoặc **U.S.** khi dùng {{AppName}}. Bạn có thể giữ hoặc gỡ nguồn nhập tiếng Việt của macOS.
3. Mở lại {{AppName}} rồi thử gõ trong ô gõ thử.

Nếu vẫn lặp chữ, bạn gửi giúp mình báo cáo từ mục **Báo lỗi...** nhé, phần chẩn đoán có ghi những bộ gõ khác mà {{AppName}} phát hiện được.

### English

Two input methods running at once cause doubled or lost letters. It looks like {{OtherApp}} (or macOS's built-in Vietnamese input source) is running. Please:

1. Quit {{OtherApp}} (click its menu-bar icon and choose Quit) and turn off its open-at-login option. {{AppNameTM}} never quits or modifies other apps for you.
2. If you use macOS's built-in **Vietnamese** input source: open **System Settings > Keyboard > Input Sources** and choose the **ABC** or **U.S.** keyboard while using {{AppName}}. You may keep or remove the built-in Vietnamese source.
3. Reopen {{AppName}} and try the practice field.

If letters are still doubled, send a report from **Report a problem...**; the diagnostics list the other input apps that {{AppName}} detected.

---

## 5. Known limitation

Use when the app is on the "Hạn chế đã biết" list. Each limitation text must be verified before it is published (PRD-R35 VERIFY). Label the issue `known-limitation` and link the matrix entry.

### Vietnamese

Cảm ơn bạn đã báo. Đây là một **hạn chế đã biết** của <Tên ứng dụng> <phiên bản>: <mô tả một câu, không dùng thuật ngữ kỹ thuật>. Nguyên nhân nằm ở cách ứng dụng đó (hoặc macOS) xử lý phím gõ, nên {{AppNameTM}} chưa thể sửa hoàn toàn ở phía mình.

Cách tạm thời: <cách khắc phục, từng bước ngắn>.

Mình đã ghi vào bảng tương thích (mục "Hạn chế đã biết") và gắn nhãn `known-limitation`. Nếu sau này có cách khắc phục, mình sẽ cập nhật tại đây và trong ghi chú phát hành.

### English

Thank you for reporting this. It is a **known limitation** of <App name> <version>: <one-sentence description in plain words>. The cause is in how that app (or macOS) handles typed keys, so {{AppNameTM}} cannot fully fix it on its side yet.

Workaround for now: <short step-by-step workaround>.

We recorded it in the compatibility matrix ("Known limitation") and labelled the issue `known-limitation`. If a fix becomes possible we will update this issue and the release notes.

---

## 6. Switch to beta

Use when a fix is `fixed-in-beta` and you want the reporter to confirm it (QA-R46 step 2), or a user asks for early builds.

### Vietnamese

Bản sửa đã có trong bản beta **<phiên bản beta>**. Bạn thử giúp mình nhé:

1. Mở {{AppName}} > **Cài đặt...** > **Giới thiệu**.
2. Ở mục **Kênh cập nhật**, chọn **Beta**.
3. Bấm **Kiểm tra cập nhật...** và cài bản beta mới nhất.
4. Thử lại đúng trường hợp bị lỗi trước đây và cho mình biết kết quả.

Người dùng beta cũng nhận các bản ổn định mới hơn bản beta mới nhất. Muốn quay lại kênh ổn định, bạn chọn lại **Ổn định** ở cùng mục đó. Lưu ý: chuyển từ beta về ổn định sẽ không tự hạ phiên bản, bạn sẽ nhận bản ổn định kế tiếp khi nó mới hơn bản đang dùng.

### English

The fix is in beta **<beta version>**. Please try it:

1. Open {{AppName}} > **Settings...** > **About**.
2. Under **Update channel**, choose **Beta**.
3. Click **Check for Updates...** and install the latest beta.
4. Retry the exact case that failed before and tell us the result.

Beta users also receive stable releases that are newer than the latest beta. To go back, choose **Stable** in the same place. Note that switching from beta back to stable does not downgrade automatically; you get the next stable release once it is newer than the version you run.

---

## 7. Lifecycle

QA-R46 and QA-R47. An issue is not closed when a fix is merged.

### 7.1 Fixed in beta (ask the reporter to confirm)

Vietnamese: Lỗi này đã được sửa trong bản beta **<phiên bản>**. Bạn thử giúp mình theo hướng dẫn chuyển sang kênh beta ở trên và cho mình biết kết quả, để mình đóng issue khi đã được xác nhận.

English: This is fixed in beta **<version>**. Could you try it using the beta-channel steps above and tell us the result? We close the issue once it is confirmed.

### 7.2 Fixed in release

Vietnamese: Bản sửa đã có trong bản ổn định **<phiên bản>**. Bạn cập nhật rồi cho mình biết lỗi còn không nhé. Nếu không nghe phản hồi, mình sẽ đóng issue sau 14 ngày và bạn vẫn có thể mở lại bất cứ lúc nào.

English: The fix is in stable **<version>**. Please update and tell us whether it is gone. If we hear nothing we will close the issue after 14 days, and you can reopen it at any time.

### 7.3 Closed as unverified (14 days after `fixed-in-release`, no response)

Vietnamese: Mình đóng issue này vì đã qua 14 ngày kể từ khi bản sửa được phát hành mà chưa nhận được phản hồi. Nếu lỗi vẫn còn, bạn cứ bình luận hoặc mở lại, mình sẽ xem lại ngay và thêm kiểm thử mới cho đúng trường hợp của bạn.

English: Closing this because 14 days have passed since the fix shipped and we have not heard back. If it is still broken, just comment or reopen it; we will look again and add a new test for your exact case.

### 7.4 Needs info (close after 21 days without the information)

Vietnamese (lần đầu): Để tìm được nguyên nhân, mình cần thêm: <thông tin cần>. Bạn gửi giúp mình qua mục **Báo lỗi...** trong ứng dụng, không cần nhật ký hay lệnh nào.

Vietnamese (khi đóng): Mình đóng issue này vì chưa nhận được thông tin cần thiết sau 21 ngày. Bất cứ khi nào có thêm thông tin, bạn cứ mở lại nhé.

English (first ask): To find the cause we need: <information>. Please send it through **Report a problem...** in the app; no logs or commands needed.

English (closing): Closing because we have not received the information after 21 days. Reopen it whenever you have more.

### 7.5 Reopened

Vietnamese: Cảm ơn bạn đã báo lại. Mình mở lại issue và gắn nhãn `reopened`. Lần sửa tiếp theo sẽ có thêm một kiểm thử tái hiện đúng phần còn lỗi.

English: Thanks for letting us know. We reopened the issue and added the `reopened` label. The next fix will come with a new test that reproduces the remaining failure.
