// SPDX-License-Identifier: GPL-3.0-or-later
// Vietnamese support copy: FAQ, troubleshooting by symptom, bug reporting, response targets (QA-R52),
// and the migration guides (PRD-R71). Migration steps describe only what a user sees in the other app's
// own window; every such step is marked VERIFY until checked on a real install (CLR-R5).
// "file", never "tệp", as the app says it (Nhập từ file..., Lưu file...); the URL slug tep-van-ban stays, links to it
// exist. {{AppNameTM}} as in content/vi/pages.mjs: the first prose mention of a block, never headings, FAQ questions,
// on-screen steps (open, quit, its menu, a list or folder), paths or identifiers.
export const support = {
  h1: "Hỗ trợ",
  lede: "Tìm câu trả lời nhanh bên dưới. Nếu vẫn chưa được, báo lỗi theo hướng dẫn ở cuối trang.",
  tocLabel: "Nội dung trang",
  toc: [["cau-hoi", "Câu hỏi thường gặp"], ["xu-ly", "Xử lý theo triệu chứng"], ["bao-loi", "Cách báo lỗi"], ["thoi-gian-phan-hoi", "Thời gian phản hồi"], ["chuyen-tu", "Chuyển từ bộ gõ khác"]],
  faqHeading: "Câu hỏi thường gặp",
  faq: [
    ["Vì sao không có tùy chọn \"gõ dấu ở vị trí bất kỳ\"?", "Vì tính năng đó luôn bật và không phải cài đặt. Bạn gõ phím dấu sau phụ âm cuối (<code>vieetj</code>, <code>tieengs</code>), ở giữa từ, hoặc phím <code>d</code> thứ hai ở cuối từ (<code>dangd</code>) đều ra đúng."],
    ["Từ tiếng Anh vẫn bị thêm dấu, hoặc từ tiếng Việt bị giữ nguyên thì sao?", "Mở Cài đặt, mục Kiểu gõ. Ở phần khôi phục tiếng Anh có hai danh sách: \"giữ nguyên như đã gõ\" và \"giữ là tiếng Việt\". Thêm từ đó vào danh sách tương ứng là xong. Bạn cũng có thể báo từ đó để được xem xét thêm vào dữ liệu."],
    ["Vì sao không có gõ tắt phụ âm nhanh (cc thành ch, kk thành kh)?", "Vì tính năng này làm sai cả những từ bình thường (<code>cc</code> thành <code>ch</code>, <code>kkk</code> thành <code>khk</code>). {{AppNameTM}} cố ý không có, kể cả dạng tùy chọn."],
    ["Dấu thanh đặt kiểu <em>hòa</em> hay <em>hoà</em>?", "Mặc định là kiểu truyền thống (<em>hòa</em>, <em>thủy</em>, <em>khỏe</em>). Kiểu mới (<em>hoà</em>, <em>thuỷ</em>, <em>khoẻ</em>) chỉ cách một công tắc trong Cài đặt, mục Kiểu gõ."],
    ["Có hỗ trợ bảng mã TCVN3, VNI-Windows hay CP1258 không?", "Không. {{AppNameTM}} chỉ xuất Unicode dựng sẵn (NFC), là định dạng mọi ứng dụng hiện nay đều đọc được."],
    ["Phím chuyển Việt/Anh là gì, đổi được không?", "Mặc định là nhấn rồi thả <kbd>Control</kbd> + <kbd>Shift</kbd>. Bạn đổi trong Cài đặt, mục Chung. Nếu bạn chọn tổ hợp macOS đã dùng (ví dụ Command+Space), ứng dụng vẫn cho chọn nhưng cảnh báo bạn tính năng nào của macOS đang dùng nó. Xem <a href=\"#phim-tat-macos\">cách tắt phím tắt đó của macOS</a>."],
    ["Escape khôi phục từ vừa gõ. Ở những ứng dụng nào phím này tự tắt?", "Bấm <kbd>Escape</kbd> ngay sau một từ, {{AppNameTM}} trả lại đúng các phím bạn đã gõ; bấm thêm lần nữa thì Escape hoạt động như bình thường, nên vẫn đóng được hộp thoại. {{AppName}} tự tắt tính năng này ở những nơi Escape có việc riêng: Terminal, iTerm2 và các ứng dụng dòng lệnh khác, kể cả cửa sổ dòng lệnh trong trình soạn mã; Visual Studio Code và các trình soạn mã dựa trên nó (VSCodium, Cursor và các ứng dụng khác); các IDE của JetBrains và Android Studio; Xcode, Nova, BBEdit, Sublime Text, Zed, Emacs và MacVim; ứng dụng điều khiển máy từ xa và máy ảo, kể cả Chrome Remote Desktop trên trình duyệt; trò chơi; Spotlight, Raycast và Alfred. Muốn tắt hẳn phím này hoặc chọn phím khác, bạn mở Cài đặt, mục Kiểu gõ."],
    ["Vì sao {{AppName}} tạm dừng khi tôi chọn bàn phím tiếng Nhật, Trung hay Hàn?", "Khi bạn chọn một nguồn nhập không dùng chữ Latinh (tiếng Nhật, tiếng Trung, tiếng Hàn và các ngôn ngữ tương tự), {{AppNameTM}} tự tạm dừng và làm mờ biểu tượng trên thanh menu, để phím đi thẳng tới bộ gõ đó: gõ <code>kore</code> trong bộ gõ tiếng Nhật không bị biến thành <code>kỏe</code>. Chọn lại bàn phím ABC hoặc U.S. là {{AppName}} gõ tiếng Việt tiếp. Đây là chủ ý và không phải cài đặt."],
    ["{{AppName}} có gõ được trong ô mật khẩu không?", "Ô mật khẩu luôn được bỏ qua, phím đi thẳng tới ứng dụng. Đây là chủ ý và không phải cài đặt."],
    ["Tôi dùng bàn phím QWERTZ, AZERTY, Dvorak hay Colemak thì sao?", "Dùng được. {{AppNameTM}} theo bố cục bàn phím macOS bạn đang chọn, không cần cài đặt thêm."],
    ["Ứng dụng có gửi nội dung tôi gõ đi đâu không?", "Không. Xem trang <a href=\"{{hrefPrivacy}}\">Riêng tư</a> để biết chính xác ứng dụng lưu và gửi gì."],
    ["Mac của tôi chạy macOS 11 hoặc cũ hơn?", "{{AppNameTM}} yêu cầu macOS 12 Monterey trở lên, trên máy Apple silicon hoặc Intel. Xem trang <a href=\"{{hrefDownload}}\">Tải về</a> để biết con số hiện hành."],
    ["Gỡ cài đặt thế nào?", "Thoát {{AppName}}, kéo ứng dụng vào Thùng rác. Để xóa cả dữ liệu, xem mục cuối trang <a href=\"{{hrefPrivacy}}#xoa-du-lieu\">Riêng tư</a>."],
  ],
  fixHeading: "Xử lý theo triệu chứng",
  fix: {
    permission: {
      id: "quyen",
      h: "Đã cấp quyền nhưng vẫn không gõ được",
      html: `
<p>{{AppNameTM}} cần quyền để nhận phím gõ. Tên mục thay đổi theo phiên bản macOS:</p>
<ul>
  <li>macOS 12: Tùy chọn Hệ thống &gt; Bảo mật &amp; Quyền riêng tư &gt; Quyền riêng tư &gt; <strong>Trợ năng</strong> (bấm vào ổ khóa để thay đổi).</li>
  <li>macOS 13 tới 26: Cài đặt hệ thống &gt; Quyền riêng tư &amp; Bảo mật &gt; <strong>Trợ năng</strong>.</li>
  <li>macOS 27: Cài đặt hệ thống &gt; Quyền riêng tư &amp; Bảo mật &gt; <strong>Điều khiển thiết bị và truy cập dữ liệu</strong> (tên tiếng Anh: <em>Device Control and Data Access</em>; trước đây là Accessibility). {{verifyHtml}}</li>
</ul>
<ol class="steps">
  <li>Bảo đảm {{AppName}} nằm trong thư mục <code>/Applications</code> (hoặc <code>~/Applications</code>), không chạy từ DMG.</li>
  <li>Bật công tắc của {{AppName}} trong mục trên. Ứng dụng tự nhận ra trong vòng vài giây.</li>
  <li>Công tắc đã bật nhưng không có tác dụng (thường xảy ra sau khi cập nhật macOS): chọn {{AppName}} trong danh sách, bấm nút trừ (-) để xóa, rồi thêm lại. Hoặc dùng nút <em>Đặt lại quyền</em> trong ứng dụng, chỉ đặt lại quyền của riêng {{AppName}}.</li>
  <li>Muốn tự làm trong Terminal: <code>tccutil reset Accessibility {{bundleId}}</code>. Luôn ghi kèm mã định danh ứng dụng. Đừng chạy <code>sudo tccutil reset Accessibility</code> không kèm mã định danh, vì lệnh đó xóa quyền của mọi ứng dụng. {{verifyHtml}} Tên dịch vụ có thể khác trên macOS 27.</li>
</ol>
<p>Trong lúc thiếu quyền, bàn phím vẫn gõ bình thường; {{AppName}} chỉ tạm dừng và không chặn phím.</p>`,
    },
    secure: {
      id: "nhap-bao-mat",
      h: "Gõ tiếng Việt bị tạm dừng, menu báo \"chế độ nhập bảo mật\"",
      html: `
<p>Khi một ứng dụng bật <em>Secure Event Input</em> của macOS, hệ thống ngừng gửi phím cho mọi bộ gõ chạy nền, không riêng gì {{AppNameTM}}. Thường là do một ô mật khẩu còn mở. {{AppName}} chỉ tạm dừng khi macOS báo chế độ này đang bật hoặc khi ô đang chọn thật sự là ô mật khẩu. {{AppName}} không đoán, và tiếp tục ngay ở phím đầu tiên sau khi chế độ này tắt.</p>
<p>Menu của {{AppName}} nêu ứng dụng có thể đang giữ chế độ này (đây là phỏng đoán tốt nhất, đôi khi chưa chính xác):</p>
<ul>
  <li><strong>Terminal</strong>: tắt mục <em>Nhập dùng Bàn phím An Toàn (Secure Keyboard Entry)</em> trong menu Terminal.</li>
  <li><strong>iTerm2</strong>: iTerm2 đang bật Nhập bàn phím an toàn. Hãy tắt mục <em>iTerm2 &gt; Secure Keyboard Entry</em>, hoặc nhập xong (hay hủy) lời nhắc mật khẩu đang chờ.</li>
  <li><strong>Trình duyệt</strong>: bấm ra ngoài ô mật khẩu hoặc chuyển sang thẻ khác.</li>
  <li><strong>Trình quản lý mật khẩu</strong> hoặc ứng dụng khác: đóng cửa sổ nhập mật khẩu của nó.</li>
  <li>Không biết ứng dụng nào, hoặc menu chỉ ra <code>loginwindow</code>: khóa màn hình rồi mở lại (<kbd>Control</kbd> + <kbd>Command</kbd> + <kbd>Q</kbd>), hoặc đăng xuất rồi đăng nhập lại.</li>
</ul>`,
    },
    conflict: {
      id: "bo-go-khac",
      h: "Chữ bị lặp hoặc mất",
      html: `
<p>Hai bộ gõ chạy cùng lúc sẽ làm lặp hoặc mất chữ. Bạn nên thoát bộ gõ kia và tắt nó khi đăng nhập. {{AppNameTM}} sẽ báo khi phát hiện, nhưng không tự thoát hay chỉnh ứng dụng khác.</p>
<ol class="steps">
  <li>Thoát bộ gõ cũ (XKey, OpenKey, EVKey, Gõ Nhanh, PHTV hoặc tương tự) từ biểu tượng trên thanh menu.</li>
  <li>Cài đặt hệ thống &gt; Cài đặt chung &gt; Mục đăng nhập &amp; Phần mở rộng: xóa bộ gõ cũ khỏi danh sách mở khi đăng nhập. {{verifyHtml}}</li>
  <li>Nếu bạn đang bật bộ gõ <em>Tiếng Việt</em> có sẵn của macOS, hãy chọn bàn phím ABC hoặc U.S. khi dùng {{AppName}}.</li>
</ol>
<p>Hướng dẫn riêng cho từng ứng dụng nằm ở mục <a href="#chuyen-tu">chuyển từ bộ gõ khác</a>.</p>`,
    },
    app: {
      id: "ung-dung-cu-the",
      h: "Chỉ lỗi ở một ứng dụng",
      html: `
<ol class="steps">
  <li>Tìm tên ứng dụng đó trong <a href="{{repo}}/issues" rel="noopener">GitHub Issues</a>: có thể đã có người báo và có cách xử lý.</li>
  <li>Thử gõ trong ô gõ thử của {{AppName}} (nút <em>Thử trong ô gõ thử</em> khi báo lỗi) để biết lỗi chỉ xảy ra ở ứng dụng đó hay ở mọi nơi.</li>
  <li>Trong menu {{AppName}}, mục <em>Với tên ứng dụng</em> có thể đặt <em>Luôn tiếng Anh</em> hoặc <em>Bỏ qua ứng dụng này</em> nếu bạn cần làm việc ngay.</li>
  <li>Báo lỗi bằng <em>Báo lỗi với ứng dụng này...</em>: báo cáo tự điền sẵn ứng dụng, phiên bản và quy tắc đang áp dụng.</li>
</ol>`,
    },
    shortcuts: {
      id: "phim-tat-macos",
      h: "Phím chuyển trùng với phím tắt của macOS",
      html: `
<p>Nếu bạn chọn một tổ hợp phím mà macOS đang dùng, {{AppNameTM}} vẫn lưu lựa chọn và hiện cảnh báo nêu tính năng của macOS dùng tổ hợp đó. Để tổ hợp chỉ dành cho {{AppName}}, hãy tắt hoặc đổi phím tắt đó trong macOS:</p>
<ol class="steps">
  <li>Mở Cài đặt hệ thống &gt; Bàn phím, bấm <em>Phím tắt bàn phím...</em>. {{verifyHtml}} Tên mục tiếng Việt trên từng phiên bản macOS.</li>
  <li>Chọn nhóm ở cột bên trái (xem danh sách dưới đây), rồi bỏ chọn ô của phím tắt để tắt nó, hoặc bấm đúp vào tổ hợp phím để gán tổ hợp khác.</li>
</ol>
<ul>
  <li><kbd>Command</kbd> + <kbd>Space</kbd>: nhóm <em>Spotlight</em>, mục hiện tìm kiếm Spotlight.</li>
  <li><kbd>Control</kbd> + <kbd>Space</kbd> và <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>Space</kbd>: nhóm <em>Nguồn nhập</em>, mục chọn nguồn nhập trước đó và mục chọn nguồn tiếp theo. {{verifyHtml}} Tên nhóm tiếng Việt.</li>
  <li><kbd>Control</kbd> + <kbd>Command</kbd> + <kbd>Space</kbd>: mở bảng Emoji và ký hiệu. Phím tắt này nằm trong menu Sửa của từng ứng dụng, không có trong các nhóm trên; bạn có thể gán tổ hợp khác cho mục menu đó ở nhóm <em>Phím tắt ứng dụng</em>. {{verifyHtml}} Tên mục menu và nhóm trên từng phiên bản macOS.</li>
  <li><kbd>Command</kbd> + <kbd>Tab</kbd> (chuyển ứng dụng), <kbd>Command</kbd> + <kbd>Q</kbd> (thoát ứng dụng) và <kbd>Command</kbd> + <kbd>W</kbd> (đóng cửa sổ): macOS không cho tắt các phím tắt này. Bạn nên chọn tổ hợp khác cho {{AppName}}.</li>
</ul>
<p>{{AppName}} không đọc cài đặt phím tắt của macOS, nên cảnh báo trong Cài đặt vẫn hiện sau khi bạn đã tắt phím tắt đó. Khi đó bạn có thể bỏ qua cảnh báo.</p>`,
    },
  },
  reportHeading: "Cách báo lỗi",
  reportIntro: "Cách nhanh nhất là dùng ngay trong ứng dụng: menu {{AppName}} &gt; <em>Báo lỗi...</em>.",
  reportSteps: [
    "Chọn ứng dụng bị lỗi (đã chọn sẵn ứng dụng bạn vừa dùng).",
    "Chọn chuyện gì xảy ra: mất chữ, lặp chữ, sai dấu, không gõ được tiếng Việt, chậm hoặc giật, khác.",
    "Tự gõ lại ví dụ bạn đã gõ và kết quả bạn mong muốn. {{AppNameTM}} không tự gửi những gì bạn đã gõ.",
    "Bấm <em>Xem trước dữ liệu sẽ gửi</em> để thấy chính xác báo cáo. Rồi chọn <em>Mở GitHub</em> (báo cáo được sao chép vào bảng nhớ tạm để bạn dán vào), <em>Gửi qua email</em>, hoặc <em>Lưu file...</em>.",
  ],
  reportNoGithub: "Bạn không cần tài khoản GitHub: đường email luôn dùng được.",
  reportNever: "{{AppNameTM}} sẽ không bao giờ yêu cầu bạn gửi nhật ký chi tiết hay nội dung bạn đã gõ. Chỉ khi thật sự cần, người duy trì mới mời bạn ghi một đoạn thao tác gõ ngắn (60 giây), bạn tự xem lại trước khi chia sẻ.",
  channelsHeading: "Kênh hỗ trợ",
  channels: [
    "<a href=\"{{repo}}/issues/new/choose\" rel=\"noopener\">GitHub Issues</a>: báo lỗi và tương thích ứng dụng.",
    "<a href=\"{{repo}}/discussions\" rel=\"noopener\">GitHub Discussions</a>: câu hỏi và ý tưởng.",
    "Email <a href=\"mailto:{{email}}\">{{email}}</a> {{verifyHtml}} dành cho bạn nào không dùng GitHub.",
  ],
  noDm: "Xin lỗi, chúng tôi không hỗ trợ qua tin nhắn riêng trên mạng xã hội. Dùng các kênh trên giúp mọi người cùng thấy câu trả lời.",
  targetsHeading: "Thời gian phản hồi",
  targetsNote: "Đây là mục tiêu, tính theo ngày làm việc và cố gắng hết sức. Đây là dự án cá nhân của một người.",
  targetsCols: ["Mức độ", "Phản hồi đầu tiên", "Mục tiêu xử lý"],
  targets: [
    ["P0 (mất chữ, treo máy, không gõ được)", "24 giờ", "Rút bản cập nhật hoặc đưa ra cách tạm trong 24 giờ sau khi xác nhận; bản sửa hoặc bản quay lui trong 72 giờ"],
    ["P1", "3 ngày", "Bản beta kế tiếp; bản ổn định kế tiếp"],
    ["P2", "7 ngày", "Đưa vào kế hoạch của một mốc phát hành, hoặc gắn nhãn hạn chế đã biết kèm giải thích"],
    ["P3 và đề xuất tính năng", "Xem xét hằng tháng", "Trả lời: nhận, từ chối kèm lý do, hoặc \"để sau\""],
  ],
  absence: "Khi Kal vắng mặt quá một tuần, trang web sẽ có thông báo kèm ngày dự kiến quay lại.",
  migrateHeading: "Chuyển từ bộ gõ khác",
  migrateLede: "Hướng dẫn chuyển danh sách viết tắt từ bộ gõ bạn đang dùng. Hiện {{AppNameTM}} nhập danh sách viết tắt từ file văn bản (phân tách bằng Tab hoặc CSV), từ file Thay thế văn bản của macOS và từ file xuất của chính nó; chưa đọc file xuất của bộ gõ khác. {{AppName}} chỉ nhập file bạn tự chọn, và chỉ sau khi bạn bấm nhập. Ứng dụng không tự đọc dữ liệu của ứng dụng khác.",
};

export const migrate = {
  title: "Chuyển từ {{Other}} sang {{AppName}}",
  // [name in the card list, what moves, name inside a sentence ({{Other}}) when it is not a proper name]
  indexNames: {
    xkey: ["XKey", "Viết tắt, qua mẫu file văn bản"],
    openkey: ["OpenKey", "Viết tắt, qua mẫu file văn bản"],
    evkey: ["EVKey", "Viết tắt, qua mẫu file văn bản"],
    gonhanh: ["Gõ Nhanh", "Viết tắt, qua mẫu file văn bản"],
    phtv: ["PHTV", "Viết tắt, qua mẫu file văn bản"],
    macos: ["Bộ gõ Tiếng Việt có sẵn của macOS", "Thay thế văn bản (Text Replacements)", "bộ gõ Tiếng Việt có sẵn của macOS"],
    plaintext: ["File văn bản hoặc CSV", "Viết tắt, định dạng chung cho mọi nguồn", "file văn bản hoặc CSV"],
  },
  back: "Quay lại phần Hỗ trợ",
  stepsHeading: "Lấy danh sách viết tắt từ {{Other}}",
  importHeading: "Nhập vào {{AppName}}",
  importSteps: [
    "Mở {{AppName}}, vào Cài đặt &gt; Viết tắt &gt; <em>Nhập từ file...</em> (hoặc chọn <em>Chọn file...</em> ở bước nhập trong lúc làm quen).",
    "Xem bảng xem trước: số dòng mới, trùng lặp và không hợp lệ. Với dòng trùng, chọn giữ bản của bạn hoặc dùng bản nhập vào.",
    "Dòng không hợp lệ được bỏ qua kèm lý do; một dòng lỗi không làm hỏng cả lần nhập.",
  ],
  quitHeading: "Thoát {{Other}} và tắt tự mở khi đăng nhập",
  quitIntro: "Hai bộ gõ cùng lúc sẽ làm lặp hoặc mất chữ. Bạn nên thoát {{Other}} và tắt nó khi đăng nhập.",
  quitSteps: [
    "Bấm biểu tượng {{Other}} trên thanh menu và chọn thoát. {{verifyHtml}} Tên mục trong bản hiện tại.",
    "Mở Cài đặt hệ thống &gt; Cài đặt chung &gt; Mục đăng nhập &amp; Phần mở rộng. Trong danh sách <em>Mở khi đăng nhập</em>, chọn {{Other}} rồi bấm nút trừ (-). {{verifyHtml}} Tên mục trên từng phiên bản macOS.",
    "Nếu {{Other}} có tùy chọn tự khởi động riêng trong cài đặt của nó, hãy tắt luôn. {{verifyHtml}}",
  ],
  screenshotHolder: "Ảnh chụp màn hình sẽ được thêm sau khi từng bước được kiểm tra trên bản cài thật",
  screenshotAlt: "Ảnh minh họa (giữ chỗ): các bước xuất dữ liệu từ {{Other}}",
  verifyNote: "Các bước trên mô tả những gì bạn thấy trên màn hình của ứng dụng đó và chưa được kiểm tra trên bản mới nhất. Nếu tên mục khác, hãy làm theo mục gần nghĩa nhất và cho chúng tôi biết để sửa trang này.",
  pages: {
    xkey: {
      intro: "{{AppNameTM}} chưa đọc được file xuất của {{Other}}. Hiện tại bạn mang danh sách viết tắt sang bằng <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, rồi chọn lại kiểu gõ, kiểu đặt dấu và các ứng dụng cần bỏ qua trong {{AppName}}. Việc nhập thẳng file xuất của {{Other}} (danh sách viết tắt và các cài đặt đó) đang được lên kế hoạch, sau khi định dạng file được kiểm tra từ một file xuất thật.",
      steps: [
        "Mở cài đặt của {{Other}} từ biểu tượng trên thanh menu và tìm danh sách viết tắt (macro). {{verifyHtml}} Tên mục.",
        "Nếu {{Other}} có nút xuất danh sách viết tắt, lưu file ra Desktop và mở bằng TextEdit để chép nội dung. {{verifyHtml}} Có nút xuất hay không, và định dạng file.",
        "Chép từng dòng (chữ viết tắt, nội dung) sang một file văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, lưu với mã hóa UTF-8.",
        "Ghi lại kiểu gõ, kiểu đặt dấu và các ứng dụng bạn loại trừ trong {{Other}}. Chọn lại kiểu gõ và kiểu đặt dấu trong Cài đặt của {{AppName}}, mục Kiểu gõ; với mỗi ứng dụng cần loại trừ, dùng mục <em>Bỏ qua ứng dụng này</em> trong menu {{AppName}}.",
      ],
    },
    openkey: {
      intro: "{{AppNameTM}} chưa đọc được file xuất của {{Other}}. Hiện tại bạn mang danh sách viết tắt sang bằng <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>. Việc nhập thẳng file xuất của {{Other}} đang được lên kế hoạch, sau khi định dạng file được kiểm tra từ một file xuất thật.",
      steps: [
        "Mở danh sách viết tắt trong cài đặt của {{Other}}. {{verifyHtml}}",
        "Nếu có nút xuất, lưu file ra Desktop và mở bằng TextEdit để chép nội dung. {{verifyHtml}} Tên nút và định dạng file.",
        "Chép từng dòng (chữ viết tắt, nội dung) sang một file văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, lưu với mã hóa UTF-8.",
      ],
    },
    evkey: {
      intro: "{{Other}} (bản cũ cho macOS hoặc bản viết lại) có thể chỉ giữ danh sách viết tắt bên trong ứng dụng, và {{AppNameTM}} chưa đọc được file xuất của {{Other}}. Bạn mang danh sách viết tắt sang bằng <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>.",
      steps: [
        "Mở danh sách viết tắt trong cài đặt của {{Other}}. {{verifyHtml}}",
        "Nếu có nút xuất, lưu file ra Desktop và mở bằng TextEdit để chép nội dung. {{verifyHtml}} Nút xuất có tồn tại trong bản của bạn hay không.",
        "Chép từng dòng (chữ viết tắt, nội dung) sang một file văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, lưu với mã hóa UTF-8.",
      ],
    },
    gonhanh: {
      intro: "Khả năng xuất dữ liệu của {{Other}} cần được xác minh, và {{AppNameTM}} chưa đọc được file xuất của {{Other}}. Bạn mang danh sách viết tắt sang bằng <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, rồi đặt lại chế độ cho từng ứng dụng trong menu {{AppName}}.",
      steps: [
        "Mở cài đặt của {{Other}} và tìm danh sách viết tắt, hoặc chức năng xuất hay sao lưu. {{verifyHtml}} Chức năng này có tồn tại hay không.",
        "Chép từng dòng (chữ viết tắt, nội dung) sang một file văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, lưu với mã hóa UTF-8.",
      ],
    },
    phtv: {
      intro: "{{AppNameTM}} chưa đọc được file xuất của {{Other}}. Hiện tại bạn mang danh sách viết tắt sang bằng <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>. Việc nhập thẳng file xuất của {{Other}} đang được lên kế hoạch, sau khi định dạng file được kiểm tra từ một file xuất thật.",
      steps: [
        "Mở danh sách viết tắt trong cài đặt của {{Other}}. {{verifyHtml}}",
        "Nếu có nút xuất, lưu file ra Desktop và mở bằng TextEdit để chép nội dung. {{verifyHtml}} Tên mục, nút và định dạng file.",
        "Chép từng dòng (chữ viết tắt, nội dung) sang một file văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu file văn bản</a>, lưu với mã hóa UTF-8.",
      ],
    },
    macos: {
      intro: "Bộ gõ Tiếng Việt có sẵn của macOS không có gì để nhập. Thứ bạn có thể mang theo là danh sách Thay thế văn bản (Text Replacements). Bạn có thể giữ hoặc gỡ bộ gõ Tiếng Việt của macOS. Khi dùng {{AppNameTM}}, hãy chọn bàn phím ABC hoặc U.S.",
      steps: [
        "Mở Cài đặt hệ thống &gt; Bàn phím &gt; <em>Thay thế văn bản</em>. {{verifyHtml}} Tên mục tiếng Việt trên từng phiên bản macOS.",
        "Chọn các dòng muốn mang theo (<kbd>Command</kbd> + <kbd>A</kbd> để chọn hết) rồi kéo ra Desktop. macOS tạo một file <code>.plist</code>. {{verifyHtml}}",
        "Nhập file <code>.plist</code> đó vào {{AppName}} theo hướng dẫn ở trên.",
      ],
      quitSteps: [
        "Mở Cài đặt hệ thống &gt; Bàn phím &gt; Nguồn nhập (hoặc Phương thức nhập). {{verifyHtml}} Tên mục trên từng phiên bản macOS.",
        "Bấm Sửa, thêm bàn phím <em>ABC</em> hoặc <em>U.S.</em> nếu chưa có.",
        "Chọn nguồn <em>Tiếng Việt</em> có sẵn và bấm nút trừ (-) để gỡ nếu bạn không dùng nữa. Việc gỡ là tùy bạn; giữ lại không gây lỗi, miễn bạn chọn ABC hoặc U.S. khi gõ với {{AppName}}.",
      ],
    },
    plaintext: {
      intro: "Đây là cách chung, dùng được cho mọi nguồn: một file văn bản, mỗi dòng một mục viết tắt. {{AppNameTM}} nhập cả hai dạng dưới đây.",
      noQuit: true,
      html: `
<h2 id="mau-tsv">Văn bản phân tách bằng phím Tab</h2>
<p>Mỗi dòng gồm chữ viết tắt, một ký tự Tab, rồi nội dung đầy đủ. Chữ viết tắt dài 1 đến 32 ký tự ASCII in được, không có dấu cách, không có chữ tiếng Việt (vì chữ viết tắt được so khớp theo phím bạn gõ: <code>dc</code>, không phải <code>đc</code>). Nội dung dài tới 4.000 ký tự.</p>
<pre><code>vn&#9;Việt Nam
dc&#9;được
tphcm&#9;Thành phố Hồ Chí Minh</code></pre>
<h2 id="mau-csv">CSV hai cột</h2>
<pre><code>vn,Việt Nam
dc,được
"cam on","Cảm ơn bạn rất nhiều, hẹn gặp lại"</code></pre>
<p>Mã hóa UTF-8. Đặt nội dung có dấu phẩy trong dấu ngoặc kép.</p>
<h2 id="xuat-nhap-rieng">File xuất cài đặt của chính {{AppName}}</h2>
<p>Trong Cài đặt &gt; Hỗ trợ bạn xuất toàn bộ cài đặt ra một file JSON, UTF-8, tên dạng <code>{{slug}}-settings-NĂMTHÁNGNGÀY.json</code>. Trường <code>kind</code> luôn là <code>settings-export</code>; <code>schemaVersion</code> (số nguyên) là phiên bản định dạng; <code>writtenBy</code> là phiên bản ứng dụng đã ghi file; <code>exportedAt</code> là thời điểm xuất (ISO 8601, giờ UTC). Tiếp theo là <code>settings</code> (cài đặt), <code>appModes</code> (chế độ theo ứng dụng), <code>ruleOverrides</code> (quy tắc tương thích bạn tự đặt) và <code>macros</code> (danh sách viết tắt: chữ viết tắt <code>trigger</code>, nội dung <code>expansion</code>, theo chữ hoa <code>adaptCase</code>, đang bật <code>enabled</code>). Khi xuất, bạn có thể bỏ chọn danh sách viết tắt và chế độ theo ứng dụng, vì danh sách viết tắt có thể chứa chữ riêng tư; phần đã bỏ chọn sẽ không có trong file. Khi nhập file từ phiên bản mới hơn, {{AppNameTM}} nhập các trường nó hiểu và liệt kê những trường bị bỏ qua.</p>
<pre><code>{
  "kind": "settings-export",
  "schemaVersion": 1,
  "writtenBy": "0.1.0",
  "exportedAt": "2026-11-13T09:00:00Z",
  "settings": { },
  "appModes": { },
  "ruleOverrides": [ ],
  "macros": [
    { "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "trigger": "vn", "expansion": "Việt Nam", "adaptCase": true, "enabled": true }
  ]
}</code></pre>`,
    },
  },
};
