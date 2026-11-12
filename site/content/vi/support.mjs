// SPDX-License-Identifier: LicenseRef-App-Pending
// Vietnamese support copy: FAQ, troubleshooting by symptom, bug reporting, response targets (QA-R52),
// and the migration guides (PRD-R71). Migration steps describe only what a user sees in the other app's
// own window; every such step is marked VERIFY until checked on a real install (CLR-R5).
export const support = {
  h1: "Hỗ trợ",
  lede: "Tìm câu trả lời nhanh bên dưới. Nếu vẫn chưa được, báo lỗi theo hướng dẫn ở cuối trang.",
  tocLabel: "Nội dung trang",
  toc: [["cau-hoi", "Câu hỏi thường gặp"], ["xu-ly", "Xử lý theo triệu chứng"], ["bao-loi", "Cách báo lỗi"], ["thoi-gian-phan-hoi", "Thời gian phản hồi"], ["chuyen-tu", "Chuyển từ bộ gõ khác"]],
  faqHeading: "Câu hỏi thường gặp",
  faq: [
    ["Vì sao không có tuỳ chọn \"gõ dấu ở vị trí bất kỳ\"?", "Vì tính năng đó luôn bật và không phải cài đặt. Bạn gõ phím dấu sau phụ âm cuối (<code>vietj</code>, <code>tieengs</code>), ở giữa từ, hoặc phím <code>d</code> thứ hai ở cuối từ (<code>dangd</code>) đều ra đúng."],
    ["Từ tiếng Anh vẫn bị thêm dấu, hoặc từ tiếng Việt bị giữ nguyên thì sao?", "Mở Cài đặt, mục Gõ phím. Ở phần khôi phục tiếng Anh có hai danh sách: \"giữ nguyên như đã gõ\" và \"giữ là tiếng Việt\". Thêm từ đó vào danh sách tương ứng là xong. Bạn cũng có thể báo từ đó để được xem xét thêm vào dữ liệu."],
    ["Vì sao không có gõ tắt phụ âm nhanh (cc thành ch, kk thành kh)?", "Vì tính năng này làm sai cả những từ bình thường (<code>cc</code> thành <code>ch</code>, <code>kkk</code> thành <code>khk</code>). {{AppName}} cố ý không có, kể cả dạng tuỳ chọn."],
    ["Dấu thanh đặt kiểu <em>hòa</em> hay <em>hoà</em>?", "Mặc định là kiểu truyền thống (<em>hòa</em>, <em>thủy</em>, <em>khỏe</em>). Kiểu mới (<em>hoà</em>, <em>thuỷ</em>, <em>khoẻ</em>) chỉ cách một công tắc trong Cài đặt, mục Gõ phím."],
    ["Có hỗ trợ bảng mã TCVN3, VNI-Windows hay CP1258 không?", "Không. {{AppName}} chỉ xuất Unicode dựng sẵn (NFC), là định dạng mọi ứng dụng hiện nay đều đọc được."],
    ["Phím chuyển Việt/Anh là gì, đổi được không?", "Mặc định là nhấn rồi thả <kbd>Control</kbd> + <kbd>Shift</kbd>. Bạn đổi trong Cài đặt, mục Chung. Nếu bạn chọn tổ hợp macOS đã dùng (ví dụ Command+Space), ứng dụng vẫn cho chọn nhưng cảnh báo bạn tính năng nào của macOS đang dùng nó."],
    ["{{AppName}} có gõ được trong ô mật khẩu không?", "Ô mật khẩu luôn được bỏ qua, phím đi thẳng tới ứng dụng. Đây là chủ ý và không phải cài đặt."],
    ["Tôi dùng bàn phím QWERTZ, AZERTY, Dvorak hay Colemak thì sao?", "Dùng được. {{AppName}} theo bố cục bàn phím macOS bạn đang chọn, không cần cài đặt thêm."],
    ["Ứng dụng có gửi nội dung tôi gõ đi đâu không?", "Không. Xem trang <a href=\"{{hrefPrivacy}}\">Riêng tư</a> để biết chính xác ứng dụng lưu và gửi gì."],
    ["Mac của tôi chạy macOS 14 hoặc cũ hơn?", "{{AppName}} yêu cầu macOS 15 Sequoia trở lên. {{verifyHtml}} Mức tối thiểu này có thể thay đổi, xem trang <a href=\"{{hrefDownload}}\">Tải về</a> để biết con số hiện hành."],
    ["Gỡ cài đặt thế nào?", "Thoát {{AppName}}, kéo ứng dụng vào Thùng rác. Để xoá cả dữ liệu, xem mục cuối trang <a href=\"{{hrefPrivacy}}#xoa-du-lieu\">Riêng tư</a>."],
  ],
  fixHeading: "Xử lý theo triệu chứng",
  fix: {
    permission: {
      id: "quyen",
      h: "Đã cấp quyền nhưng vẫn không gõ được",
      html: `
<p>{{AppName}} cần quyền để nhận phím gõ. Tên mục thay đổi theo phiên bản macOS:</p>
<ul>
  <li>macOS 15 và 26: Cài đặt hệ thống &gt; Quyền riêng tư &amp; Bảo mật &gt; <strong>Trợ năng</strong>.</li>
  <li>macOS 27: Cài đặt hệ thống &gt; Quyền riêng tư &amp; Bảo mật &gt; <strong>Điều khiển thiết bị và truy cập dữ liệu</strong> (tên tiếng Anh: <em>Device Control and Data Access</em>; trước đây là Accessibility). {{verifyHtml}}</li>
</ul>
<ol class="steps">
  <li>Bảo đảm {{AppName}} nằm trong thư mục <code>/Applications</code> (hoặc <code>~/Applications</code>), không chạy từ DMG.</li>
  <li>Bật công tắc của {{AppName}} trong mục trên. Ứng dụng tự nhận ra trong vòng vài giây.</li>
  <li>Công tắc đã bật nhưng không có tác dụng (thường xảy ra sau khi cập nhật macOS): chọn {{AppName}} trong danh sách, bấm nút trừ (-) để xoá, rồi thêm lại. Hoặc dùng nút <em>Đặt lại quyền</em> trong ứng dụng, chỉ đặt lại quyền của riêng {{AppName}}.</li>
  <li>Muốn tự làm trong Terminal: <code>tccutil reset Accessibility {{bundleId}}</code>. Luôn ghi kèm mã định danh ứng dụng. Đừng chạy <code>sudo tccutil reset Accessibility</code> không kèm mã định danh, vì lệnh đó xoá quyền của mọi ứng dụng. {{verifyHtml}} Tên dịch vụ có thể khác trên macOS 27.</li>
</ol>
<p>Trong lúc thiếu quyền, bàn phím vẫn gõ bình thường; {{AppName}} chỉ tạm dừng và không chặn phím.</p>`,
    },
    secure: {
      id: "nhap-bao-mat",
      h: "Gõ tiếng Việt bị tạm dừng, menu báo \"chế độ nhập bảo mật\"",
      html: `
<p>Khi một ứng dụng bật <em>Secure Event Input</em> của macOS, hệ thống ngừng gửi phím cho mọi bộ gõ chạy nền, không riêng gì {{AppName}}. Thường là do một ô mật khẩu còn mở. {{AppName}} chỉ tạm dừng khi macOS báo chế độ này đang bật hoặc khi ô đang chọn thật sự là ô mật khẩu. {{AppName}} không đoán, và tiếp tục ngay ở phím đầu tiên sau khi chế độ này tắt.</p>
<p>Menu của {{AppName}} nêu ứng dụng có thể đang giữ chế độ này (đây là phỏng đoán tốt nhất, đôi khi chưa chính xác):</p>
<ul>
  <li><strong>Terminal</strong>: trong menu Terminal, tắt <em>Secure Keyboard Entry</em>.</li>
  <li><strong>iTerm2</strong>: ngoài mục <em>Secure Keyboard Entry</em> trong menu iTerm2, iTerm2 còn tự bật chế độ này khi nó cho là đang hiện dòng nhập mật khẩu. Tắt mục menu, và xem phần cài đặt phát hiện mật khẩu của iTerm2. {{verifyHtml}} Tên và vị trí cài đặt trong bản iTerm2 hiện tại, và việc nó có kích hoạt trong ứng dụng dòng lệnh tắt hiển thị phím gõ hay không.</li>
  <li><strong>Trình duyệt</strong>: bấm ra ngoài ô mật khẩu hoặc đổi sang thẻ khác.</li>
  <li><strong>Trình quản lý mật khẩu</strong> hoặc ứng dụng khác: đóng cửa sổ nhập mật khẩu của nó.</li>
  <li>Không biết ứng dụng nào, hoặc menu chỉ ra <code>loginwindow</code>: khoá màn hình rồi mở lại (<kbd>Control</kbd> + <kbd>Command</kbd> + <kbd>Q</kbd>), hoặc đăng xuất rồi đăng nhập lại.</li>
</ul>`,
    },
    conflict: {
      id: "bo-go-khac",
      h: "Chữ bị lặp hoặc mất",
      html: `
<p>Hai bộ gõ chạy cùng lúc sẽ làm lặp hoặc mất chữ. Bạn nên thoát bộ gõ kia và tắt nó khi đăng nhập. {{AppName}} sẽ báo khi phát hiện, nhưng không tự thoát hay chỉnh ứng dụng khác.</p>
<ol class="steps">
  <li>Thoát bộ gõ cũ (XKey, OpenKey, EVKey, Gõ Nhanh, PHTV hoặc tương tự) từ biểu tượng trên thanh menu.</li>
  <li>Cài đặt hệ thống &gt; Cài đặt chung &gt; Mục đăng nhập &amp; tiện ích mở rộng: xoá bộ gõ cũ khỏi danh sách mở khi đăng nhập. {{verifyHtml}}</li>
  <li>Nếu bạn đang bật bộ gõ <em>Tiếng Việt</em> có sẵn của macOS, hãy chọn bàn phím ABC hoặc U.S. khi dùng {{AppName}}.</li>
</ol>
<p>Hướng dẫn riêng cho từng ứng dụng nằm ở mục <a href="#chuyen-tu">chuyển từ bộ gõ khác</a>.</p>`,
    },
    app: {
      id: "ung-dung-cu-the",
      h: "Chỉ lỗi ở một ứng dụng",
      html: `
<ol class="steps">
  <li>Xem ứng dụng đó trong <a href="{{hrefCompat}}">danh sách tương thích</a>: có thể đã có ghi chú hoặc cách xử lý.</li>
  <li>Thử gõ trong ô gõ thử của {{AppName}} (nút <em>Thử trong ô gõ thử</em> khi báo lỗi) để biết lỗi chỉ xảy ra ở ứng dụng đó hay ở mọi nơi.</li>
  <li>Trong menu {{AppName}}, mục <em>Với tên ứng dụng</em> có thể đặt <em>Luôn tiếng Anh</em> hoặc <em>Bỏ qua ứng dụng này</em> nếu bạn cần làm việc ngay.</li>
  <li>Báo lỗi bằng <em>Báo lỗi với ứng dụng này...</em>: báo cáo tự điền sẵn ứng dụng, phiên bản và quy tắc đang áp dụng.</li>
</ol>`,
    },
  },
  reportHeading: "Cách báo lỗi",
  reportIntro: "Cách nhanh nhất là dùng ngay trong ứng dụng: menu {{AppName}} &gt; <em>Báo lỗi...</em>.",
  reportSteps: [
    "Chọn ứng dụng bị lỗi (đã chọn sẵn ứng dụng bạn vừa dùng).",
    "Chọn chuyện gì xảy ra: mất chữ, lặp chữ, sai dấu, không gõ được tiếng Việt, chậm hoặc giật, khác.",
    "Tự gõ lại ví dụ bạn đã gõ và kết quả bạn mong muốn. {{AppName}} không tự gửi những gì bạn đã gõ.",
    "Bấm <em>Xem trước dữ liệu sẽ gửi</em> để thấy chính xác báo cáo. Rồi chọn <em>Mở GitHub</em> (báo cáo được sao chép vào bảng nhớ tạm để bạn dán vào), <em>Gửi qua email</em>, hoặc <em>Lưu tệp...</em>.",
  ],
  reportNoGithub: "Bạn không cần tài khoản GitHub: đường email luôn dùng được.",
  reportNever: "{{AppName}} sẽ không bao giờ yêu cầu bạn gửi nhật ký chi tiết hay nội dung bạn đã gõ. Chỉ khi thật sự cần, người duy trì mới mời bạn ghi một đoạn thao tác gõ ngắn (60 giây), bạn tự xem lại trước khi chia sẻ.",
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
  migrateLede: "Hướng dẫn chuyển danh sách gõ tắt (và một số cài đặt) từ bộ gõ bạn đang dùng. {{AppName}} chỉ nhập từ tệp bạn tự xuất, và chỉ sau khi bạn bấm nhập. Ứng dụng không tự đọc dữ liệu của ứng dụng khác.",
};

export const migrate = {
  title: "Chuyển từ {{Other}} sang {{AppName}}",
  indexNames: {
    xkey: ["XKey", "Gõ tắt, kiểu gõ, kiểu đặt dấu, ứng dụng loại trừ"],
    openkey: ["OpenKey", "Gõ tắt"],
    evkey: ["EVKey", "Gõ tắt"],
    gonhanh: ["Gõ Nhanh", "Gõ tắt, cài đặt theo ứng dụng nếu xuất được"],
    phtv: ["PHTV", "Gõ tắt"],
    macos: ["Bộ gõ Tiếng Việt có sẵn của macOS", "Thay thế văn bản (Text Replacements)"],
    plaintext: ["Tệp văn bản hoặc CSV", "Gõ tắt, định dạng chung cho mọi nguồn"],
  },
  back: "Quay lại phần Hỗ trợ",
  stepsHeading: "Xuất dữ liệu từ {{Other}}",
  importHeading: "Nhập vào {{AppName}}",
  importSteps: [
    "Mở {{AppName}}, vào Cài đặt &gt; Gõ tắt &gt; <em>Nhập từ tệp...</em> (hoặc chọn <em>Chọn tệp...</em> ở bước nhập trong lúc làm quen).",
    "Xem bảng xem trước: số dòng mới, trùng lặp và không hợp lệ. Với dòng trùng, chọn giữ bản của bạn hoặc dùng bản nhập vào.",
    "Dòng không hợp lệ được bỏ qua kèm lý do; một dòng lỗi không làm hỏng cả lần nhập.",
  ],
  quitHeading: "Thoát {{Other}} và tắt tự mở khi đăng nhập",
  quitIntro: "Hai bộ gõ cùng lúc sẽ làm lặp hoặc mất chữ. Bạn nên thoát {{Other}} và tắt nó khi đăng nhập.",
  quitSteps: [
    "Bấm biểu tượng {{Other}} trên thanh menu và chọn thoát. {{verifyHtml}} Tên mục trong bản hiện tại.",
    "Mở Cài đặt hệ thống &gt; Cài đặt chung &gt; Mục đăng nhập &amp; tiện ích mở rộng. Trong danh sách <em>Mở khi đăng nhập</em>, chọn {{Other}} rồi bấm nút trừ (-). {{verifyHtml}} Tên mục trên từng phiên bản macOS.",
    "Nếu {{Other}} có tuỳ chọn tự khởi động riêng trong cài đặt của nó, hãy tắt luôn. {{verifyHtml}}",
  ],
  screenshotHolder: "Ảnh chụp màn hình sẽ được thêm sau khi từng bước được kiểm tra trên bản cài thật",
  screenshotAlt: "Ảnh minh hoạ (giữ chỗ): các bước xuất dữ liệu từ {{Other}}",
  verifyNote: "Các bước trên mô tả những gì bạn thấy trên màn hình của ứng dụng đó và chưa được kiểm tra trên bản mới nhất. Nếu tên mục khác, hãy làm theo mục gần nghĩa nhất và cho chúng tôi biết để sửa trang này.",
  pages: {
    xkey: {
      intro: "{{Other}} lưu danh sách gõ tắt và vài cài đặt. {{AppName}} có thể nhập: gõ tắt, kiểu gõ, kiểu đặt dấu, phím chuyển nếu biểu diễn được, và ứng dụng loại trừ (thành quy tắc <em>Bỏ qua</em>). Khoá không nhận ra sẽ bị bỏ qua và được liệt kê trong bản tóm tắt.",
      steps: [
        "Mở cài đặt của {{Other}} từ biểu tượng trên thanh menu. {{verifyHtml}}",
        "Tìm mục gõ tắt (macro) và nút xuất tệp, lưu tệp ra Desktop. {{verifyHtml}} Tên mục và nút.",
        "Nếu có chức năng xuất cài đặt chung, xuất thêm một tệp. {{verifyHtml}} Có hay không, và định dạng tệp quan sát từ một tệp xuất thật.",
        "Không tìm thấy nút xuất? Chép danh sách gõ tắt sang tệp văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu tệp văn bản</a>.",
      ],
    },
    openkey: {
      intro: "{{Other}} cho phép xuất danh sách gõ tắt. {{AppName}} nhập được phần gõ tắt.",
      steps: [
        "Mở cài đặt của {{Other}}. {{verifyHtml}}",
        "Tìm mục gõ tắt và nút xuất tệp, lưu tệp ra Desktop. {{verifyHtml}} Tên mục, nút và định dạng tệp quan sát từ một tệp xuất thật.",
        "Nếu {{AppName}} không đọc được tệp, chuyển sang <a href=\"{{hrefMigratePlaintext}}\">mẫu tệp văn bản</a>.",
      ],
    },
    evkey: {
      intro: "{{Other}} (bản cũ cho macOS hoặc bản viết lại) có thể chỉ giữ gõ tắt bên trong ứng dụng. Nếu không xuất được tệp, hãy dùng đường văn bản thuần.",
      steps: [
        "Mở danh sách gõ tắt trong cài đặt của {{Other}}. {{verifyHtml}}",
        "Nếu có nút xuất, lưu tệp ra Desktop. {{verifyHtml}} Nút xuất có tồn tại trong bản của bạn hay không.",
        "Nếu không có nút xuất: chép từng dòng (viết tắt, nội dung) sang tệp văn bản theo <a href=\"{{hrefMigratePlaintext}}\">mẫu tệp văn bản</a>.",
      ],
    },
    gonhanh: {
      intro: "Khả năng xuất dữ liệu của {{Other}} cần được xác minh. Nếu có tệp xuất, {{AppName}} nhập gõ tắt và, khi biểu diễn được, cài đặt theo ứng dụng.",
      steps: [
        "Mở cài đặt của {{Other}} và tìm chức năng xuất hoặc sao lưu. {{verifyHtml}} Chức năng này có tồn tại hay không.",
        "Nếu có, lưu tệp ra Desktop. Nếu không, dùng <a href=\"{{hrefMigratePlaintext}}\">mẫu tệp văn bản</a>.",
      ],
    },
    phtv: {
      intro: "{{AppName}} nhập được phần gõ tắt từ tệp xuất của {{Other}}.",
      steps: [
        "Mở cài đặt của {{Other}}. {{verifyHtml}}",
        "Tìm mục gõ tắt và nút xuất tệp, lưu ra Desktop. {{verifyHtml}} Tên mục, nút và định dạng tệp.",
        "Không có nút xuất? Dùng <a href=\"{{hrefMigratePlaintext}}\">mẫu tệp văn bản</a>.",
      ],
    },
    macos: {
      intro: "Bộ gõ Tiếng Việt có sẵn của macOS không có gì để nhập. Thứ bạn có thể mang theo là danh sách Thay thế văn bản (Text Replacements). Bạn có thể giữ hoặc gỡ bộ gõ Tiếng Việt của macOS. Khi dùng {{AppName}}, hãy chọn bàn phím ABC hoặc U.S.",
      steps: [
        "Mở Cài đặt hệ thống &gt; Bàn phím &gt; <em>Thay thế văn bản</em>. {{verifyHtml}} Tên mục tiếng Việt trên từng phiên bản macOS.",
        "Chọn các dòng muốn mang theo (<kbd>Command</kbd> + <kbd>A</kbd> để chọn hết) rồi kéo ra Desktop. macOS tạo một tệp <code>.plist</code>. {{verifyHtml}}",
        "Nhập tệp <code>.plist</code> đó vào {{AppName}} theo hướng dẫn ở trên.",
      ],
      quitSteps: [
        "Mở Cài đặt hệ thống &gt; Bàn phím &gt; Nguồn nhập (hoặc Phương thức nhập). {{verifyHtml}} Tên mục trên từng phiên bản macOS.",
        "Bấm Sửa, thêm bàn phím <em>ABC</em> hoặc <em>U.S.</em> nếu chưa có.",
        "Chọn nguồn <em>Tiếng Việt</em> có sẵn và bấm nút trừ (-) để gỡ nếu bạn không dùng nữa. Việc gỡ là tuỳ bạn; giữ lại không gây lỗi, miễn bạn chọn ABC hoặc U.S. khi gõ với {{AppName}}.",
      ],
    },
    plaintext: {
      intro: "Đây là cách chung, dùng được cho mọi nguồn: một tệp văn bản, mỗi dòng một gõ tắt. {{AppName}} nhập cả hai dạng dưới đây.",
      noQuit: true,
      html: `
<h2 id="mau-tsv">Văn bản phân tách bằng phím Tab</h2>
<p>Mỗi dòng gồm viết tắt, một ký tự Tab, rồi nội dung đầy đủ. Viết tắt dài 1 đến 32 ký tự ASCII in được, không có dấu cách, không có chữ tiếng Việt (vì viết tắt được so khớp theo phím bạn gõ: <code>dc</code>, không phải <code>đc</code>). Nội dung dài tới 4.000 ký tự.</p>
<pre><code>vn&#9;Việt Nam
dc&#9;được
tphcm&#9;Thành phố Hồ Chí Minh</code></pre>
<h2 id="mau-csv">CSV hai cột</h2>
<pre><code>vn,Việt Nam
dc,được
"cam on","Cảm ơn bạn rất nhiều, hẹn gặp lại"</code></pre>
<p>Mã hoá UTF-8. Đặt nội dung có dấu phẩy trong dấu ngoặc kép.</p>
<h2 id="xuat-nhap-rieng">Tệp xuất cài đặt của chính {{AppName}}</h2>
<p>Trong Cài đặt &gt; Giới thiệu &amp; Hỗ trợ bạn xuất toàn bộ cài đặt ra một tệp JSON, UTF-8, tên dạng <code>{{slug}}-settings-NĂMTHÁNGNGÀY.json</code>. Tệp có trường <code>schemaVersion</code> (số nguyên). Khi nhập tệp từ phiên bản mới hơn, {{AppName}} nhập các trường nó hiểu và liệt kê những trường bị bỏ qua. Khi xuất, bạn có thể bỏ chọn gõ tắt và chế độ theo ứng dụng, vì gõ tắt có thể chứa chữ riêng tư.</p>
<pre><code>{
  "schemaVersion": 1,
  "writtenBy": "(phiên bản ứng dụng)",
  "settings": { },
  "appRules": [ ],
  "appModes": [ ],
  "macros": [ { "shortcut": "vn", "expansion": "Việt Nam" } ]
}</code></pre>
<p>{{verifyHtml}} Tên trường chính xác sẽ được cập nhật theo bản phát hành đầu tiên; đoạn trên chỉ minh hoạ cấu trúc.</p>`,
    },
  },
};
