// SPDX-License-Identifier: GPL-3.0-or-later
// Vietnamese page copy: home, download, compatibility, changelog, privacy, donate.
// Drafts from spec/03-product.md are reused verbatim where they exist (PRD-R40, PRD-R59).
// Trusted HTML; tokens like {{AppName}} are filled at build time. Standard Vietnamese, addressed to "bạn".

// Home (design 7.3): seven sections. Prose that names the product uses {{AppNameTM}}, buttons and the install steps
// (which name the app as Finder shows it) use {{AppName}}. Demo ids name site/demo/frames.json entries; `req` cites the
// requirement whose tests prove a statement (design 7.4).
export const home = {
  h1: "Gõ tiếng Việt lẫn tiếng Anh, không cần chuyển.",
  lede: "{{AppNameTM}} bỏ dấu cho từ tiếng Việt và để nguyên từ tiếng Anh, ngay trong cùng một câu. Bạn cứ gõ một mạch, không phải bật tắt chế độ.",
  meta: "macOS {{minMacos}} trở lên · Apple silicon và Intel · Miễn phí, mã nguồn mở",
  // The chat scene of the hero. The messages stay Vietnamese on the English page: the demos type Vietnamese (7.6).
  hero: {
    windowTitle: "Trò chuyện",
    peerName: "Lan",
    peerMessage: "Buổi họp chiều nay cần chuẩn bị gì không?",
    keepTag: "{{word}}: giữ nguyên",
    pause: "Tạm dừng",
    play: "Phát tiếp",
    keysLabel: "Phím vừa gõ",
    sentLabel: "Đã gửi",
    menuBarLabel: "Đang gõ tiếng Việt",
    caption: "Ví dụ gõ Telex một mạch, không chuyển chế độ. Từ tiếng Anh giữ nguyên, từ tiếng Việt có dấu:",
  },
  behaviours: {
    heading: "Một câu, hai thứ tiếng",
    intro: "Bạn gõ tiếng Việt như bình thường. Từ tiếng Anh tự giữ nguyên, nên bạn không phải dừng lại để chuyển chế độ.",
    replay: "Xem lại",
    items: [
      {
        id: "punctuation",
        title: "Kết thúc từ kiểu nào cũng giữ nguyên",
        body: "Từ tiếng Anh vẫn giữ nguyên khi bạn kết thúc bằng dấu phẩy, dấu chấm hay phím Return.",
        note: "Trong ứng dụng trò chuyện, phím Return chỉ tới ứng dụng sau khi từ cuối đã được sửa xong, nên tin nhắn gửi đi đúng như bạn thấy.",
        noteReq: "P0-3, ENG-R910",
      },
      {
        id: "revision",
        title: "Từ sau sửa giúp từ trước",
        body: "Có những phím vừa là từ tiếng Việt vừa là từ tiếng Anh, như <code>as</code> mà Telex đọc thành <em>á</em>. Khi bạn gõ từ tiếp theo, {{AppNameTM}} xét cả hai từ và sửa lại từ trước nếu cần.",
      },
      {
        id: "escape",
        title: "Esc trả lại đúng phím bạn gõ",
        body: "Bấm Esc ngay sau một từ để lấy lại đúng các phím đã gõ: <em>Việt</em> trở về <code>Vieetj</code>.",
      },
    ],
  },
  cards: {
    heading: "Gõ theo cách của bạn",
    items: [
      {
        id: "anywhere",
        title: "Bỏ dấu ở đâu trong từ cũng được",
        body: "Phím dấu, phím mũ và phím móc đặt ở giữa hay cuối từ đều ra đúng chữ. Không có tùy chọn nào phải bật.",
        demos: ["card-anywhere"],
        req: "ENG-R107",
      },
      {
        id: "slang",
        title: "Gõ được tiếng lóng",
        body: "Phụ âm đầu như <code>dz</code> vẫn gõ bình thường, vì tính hợp lệ dựa trên quy tắc chính tả tiếng Việt chứ không dựa trên từ điển.",
        demos: ["card-slang"],
        req: "P0-2, ENG-R316",
      },
      {
        id: "method",
        title: "Telex hay VNI, đặt dấu theo ý bạn",
        body: "Chọn Telex hoặc VNI, và kiểu đặt dấu truyền thống hoặc kiểu mới. Mặc định là Telex với kiểu đặt dấu truyền thống.",
        demos: ["card-telex", "card-vni", "card-traditional", "card-modern"],
        labels: { "card-telex": "Telex", "card-vni": "VNI", "card-traditional": "Truyền thống", "card-modern": "Kiểu mới" },
        req: "D1, D2",
      },
      {
        id: "macros",
        title: "Gõ tắt của riêng bạn",
        body: "Tự đặt chữ viết tắt cho những cụm hay dùng, rồi xuất hoặc nhập cả danh sách khi đổi máy.",
        illustration: { keys: "dc", result: "được", caption: "Một gõ tắt do bạn tự đặt" },
        req: "PRD-R2",
      },
      {
        id: "layouts",
        title: "Bàn phím nào cũng gõ được",
        body: "{{AppNameTM}} đọc chữ mà bố cục bàn phím của bạn gõ ra, nên Telex và VNI chạy giống nhau trên mọi bố cục.",
        illustration: { layouts: ["QWERTY", "QWERTZ", "AZERTY", "Dvorak", "Colemak"] },
        req: "PRD-R2",
      },
      {
        id: "perApp",
        title: "Nhớ chế độ cho từng ứng dụng",
        body: "{{AppNameTM}} nhớ bạn gõ tiếng Việt hay tiếng Anh ở từng ứng dụng, và bạn có thể đặt quy tắc riêng cho một ứng dụng.",
        illustration: { apps: [{ app: "Terminal", mode: "Tiếng Anh" }, { app: "Zalo", mode: "Tiếng Việt" }] },
        req: "PRD-R2",
      },
    ],
  },
  // Section 4 never says an app was checked while every matrix entry is notVerified (design 7.3 item 4); `verifiedOn`
  // shows only beside an entry that has a current result.
  apps: {
    heading: "Chạy trong app bạn dùng hằng ngày",
    intro: "Trình duyệt, ứng dụng trò chuyện, văn phòng, ghi chú, Spotlight, Terminal và trình soạn mã. Danh sách tương thích ghi rõ tình trạng của từng ứng dụng.",
    categories: { browser: "Trình duyệt", chat: "Trò chuyện", office: "Văn phòng", notes: "Ghi chú", launcher: "Gọi nhanh", terminal: "Terminal", developer: "Soạn mã" },
    verifiedOn: "kiểm tra {{dateHtml}}",
    link: "Xem danh sách ứng dụng tương thích",
    secureInput: {
      title: "Khi macOS chặn mọi bộ gõ",
      body: "Khi một ứng dụng bật chế độ nhập bảo mật (Secure Input), thường vì một ô mật khẩu còn mở, macOS tạm dừng mọi bộ gõ. {{AppNameTM}} cho bạn biết ứng dụng nào đang giữ chế độ này và cách tắt, rồi gõ lại ngay từ phím đầu tiên sau khi chế độ này tắt. {{AppName}} không tự đoán là bạn đang gõ mật khẩu.",
      req: "P0-1, PLT-R395",
    },
  },
  proofHeading: "Ba điều bạn có thể kiểm chứng",
  proof: [
    { h: "Không thu thập dữ liệu", p: "Không telemetry, không SDK phân tích, không \"dữ liệu sử dụng ẩn danh\". {{AppNameTM}} không gửi nội dung bạn gõ đi đâu cả; lưu lượng mạng tự động duy nhất là kiểm tra cập nhật.", link: "{{hrefPrivacy}}", linkText: "Xem chi tiết về riêng tư" },
    { h: "Miễn phí", p: "{{AppNameTM}} miễn phí và sẽ luôn miễn phí. Không có tính năng nào bị khóa, không có nhắc nhở ủng hộ trong ứng dụng." },
    { h: "Mã nguồn mở", p: "Bộ máy gõ là một gói Swift theo Giấy phép Công cộng Mozilla 2.0 (MPL-2.0), viết từ đầu theo quy tắc chính tả tiếng Việt và có bộ kiểm thử riêng. Phần còn lại của ứng dụng theo giấy phép GPL-3.0-or-later.", link: "{{repo}}", linkText: "Xem mã nguồn", external: true },
  ],
  install: {
    heading: "Cài trong một phút",
    steps: [
      "Mở file DMG và kéo {{AppName}} vào thư mục Applications.",
      "Mở {{AppName}} và cấp một quyền duy nhất: <strong>Trợ năng</strong> trên macOS 12 tới 26 (trong Tùy chọn Hệ thống trên macOS 12), <strong>Điều khiển thiết bị và truy cập dữ liệu</strong> trên macOS 27. {{verifyHtml}}",
      "Gõ vài chữ vào ô gõ thử để thấy kết quả ngay.",
    ],
    brewLabel: "Hoặc cài bằng Homebrew",
  },
  closing: {
    heading: "Không cần chuyển qua chuyển lại giữa tiếng Việt và tiếng Anh nữa.",
    donateLine: "{{AppNameTM}} miễn phí. Nếu thấy có ích, bạn có thể <a href=\"{{hrefDonate}}\">ủng hộ để Kal có thêm thời gian làm tiếp</a>.",
  },
  downloadBtn: "Tải {{AppName}} {{version}}",
  downloadSub: "{{requirement}}",
  noReleaseBtn: "Chưa có bản phát hành",
  preRelease: "Trạng thái: đang phát triển, chưa phát hành công khai.",
  brewLabel: "Hoặc cài bằng Homebrew",
  allDownloads: "Tất cả bản tải và mã SHA-256",
};

export const download = {
  h1: "Tải {{AppName}}",
  lede: "Bản DMG đã ký và công chứng, chạy trên Apple silicon và Intel.",
  stableHeading: "Bản ổn định",
  betaHeading: "Bản beta",
  betaNote: "Bản beta có thể còn lỗi. Bạn có thể quay về kênh Ổn định trong Cài đặt, mục Giới thiệu & Hỗ trợ.",
  releaseDate: "Ngày phát hành",
  fileHash: "SHA-256",
  button: "Tải {{AppName}} {{version}} (DMG)",
  installHeading: "Cài đặt",
  install: [
    "Mở file DMG và kéo {{AppName}} vào thư mục Applications.",
    "Mở {{AppName}} từ thư mục Applications, không chạy trực tiếp từ DMG.",
    "Làm theo hướng dẫn trên màn hình để cấp quyền. Cả quá trình chỉ mất khoảng một phút.",
  ],
  reqHeading: "Yêu cầu hệ thống",
  reqMacos: "{{macosRequirement}}",
  reqArch: "Máy Mac dùng chip Apple silicon hoặc Intel (một bản chạy cho cả hai). macOS 27 chỉ chạy trên Apple silicon.",
  reqExcluded: "Máy Mac không cài được macOS 12 Monterey chưa được hỗ trợ. macOS 13 và 14 vẫn được hỗ trợ nhưng không được kiểm thử riêng.",
  reqPermission: "Quyền cần cấp: <strong>Trợ năng</strong> trên macOS 12 tới 26 (trong Tùy chọn Hệ thống trên macOS 12), <strong>Điều khiển thiết bị và truy cập dữ liệu</strong> trên macOS 27. {{verifyHtml}} Tên mục trong macOS tiếng Việt cần được xác minh trên từng phiên bản.",
  reqNoOthers: "{{AppName}} không xin quyền nào khác (không Ghi màn hình, không Toàn quyền truy cập ổ đĩa).",
  trustHeading: "Chữ ký và công chứng",
  trustBody: "Mỗi bản DMG được ký bằng chứng chỉ Developer ID của Kal, được Apple công chứng (notarize) và đính kèm vé công chứng (staple), nên macOS mở được mà không cảnh báo. Cập nhật tự động dùng Sparkle 2 và được ký EdDSA; ứng dụng từ chối bản cập nhật sai chữ ký.",
  verifyHeading: "Tự kiểm tra file đã tải",
  verifyBody: "So mã SHA-256 của file với mã ghi ở trên, rồi kiểm tra chữ ký sau khi cài:",
  verifyHashCmd: "shasum -a 256 &lt;đường dẫn tới file DMG&gt;",
  brewHeading: "Cài bằng Homebrew",
  brewBody: "Nếu bạn quản lý ứng dụng bằng Homebrew:",
  brewUpgrade: "Cập nhật và gỡ cài đặt:",
  archiveHeading: "Các phiên bản cũ",
  archiveBody: "Mọi bản DMG đã phát hành đều được giữ lại để bạn cài lại khi cần. Cài đặt của bạn vẫn đọc được khi lùi một phiên bản nhỏ.",
  archiveEmpty: "Chưa có phiên bản nào.",
  appcastNote: "Nguồn cập nhật cho Sparkle nằm cố định tại {{appcastUrl}}; bản beta là các mục gắn kênh <code>beta</code> trong cùng nguồn đó.",
};

export const compat = {
  h1: "Ứng dụng tương thích",
  lede: "Danh sách này được tạo tự động từ dữ liệu kiểm tra đi kèm ứng dụng. Mỗi dòng ghi trạng thái, ghi chú và ngày kiểm tra gần nhất.",
  legendHeading: "Ý nghĩa các trạng thái",
  staleNote: "Mục nào chưa được kiểm tra lại trong 120 ngày sẽ tự hiện là \"Chưa kiểm tra\".",
  jumpLabel: "Nhảy tới nhóm",
  empty: "Chưa có dữ liệu kiểm tra.",
  filterLabels: { category: "Nhóm ứng dụng", status: "Trạng thái", all: "Tất cả", shown: "Đang hiện {n} ứng dụng" },
  cols: { app: "Ứng dụng", status: "Trạng thái", notes: "Ghi chú", verified: "Kiểm tra lần cuối", macos: "macOS" },
  staleDetail: "Kết quả gần nhất ({{date}}) đã quá 120 ngày.",
  neverVerified: "Chưa từng kiểm tra",
  issuesLabel: "Báo cáo liên quan:",
  reportHeading: "Báo cáo một ứng dụng",
  reportBody: "Ứng dụng của bạn chưa có trong danh sách, hoặc kết quả không đúng với máy của bạn? Hãy gửi báo cáo tương thích. Người duy trì sẽ xác nhận trước khi đổi trạng thái thành \"Hoạt động tốt\".",
  reportLink: "Gửi báo cáo tương thích",
  reportEmail: "Không dùng GitHub? Gửi email tới {{email}}.",
};

export const changelog = {
  h1: "Nhật ký thay đổi",
  lede: "Những thay đổi bạn nhìn thấy trong từng bản phát hành, gom theo ứng dụng.",
  donateLine: "{{AppName}} miễn phí. Nếu thấy có ích, bạn có thể <a href=\"{{hrefDonate}}\">ủng hộ để Kal có thêm thời gian làm tiếp</a>.",
};

export const donate = {
  h1: "Ủng hộ {{AppName}}",
  thanks: "{{AppName}} miễn phí và sẽ luôn miễn phí. Nếu thấy có ích, bạn có thể ủng hộ để Kal có thêm thời gian làm tiếp.",
  promise: "Ủng hộ chỉ là tấm lòng. Không có tính năng nào bị khóa, và ứng dụng không bao giờ hiện lời nhắc ủng hộ.",
  // Pa's decision S8: a bank VietQR code only; the bank name and the account number are shown, never the holder's name.
  vietqr: { h: "VietQR (Napas)", alt: "Mã QR VietQR để chuyển khoản ủng hộ tới tài khoản LioBank 688688678", bankLabel: "Ngân hàng", bankValue: "LioBank", accountLabel: "Số tài khoản", accountValue: "688688678", how: "Mở ứng dụng ngân hàng và chọn quét mã QR. Ứng dụng sẽ hiện tên người nhận để bạn kiểm tra trước khi xác nhận." },
  sponsors: { h: "GitHub Sponsors", body: "Nếu bạn dùng GitHub, có thể ủng hộ định kỳ hoặc một lần.", link: "Mở trang GitHub Sponsors" },
  privacy: "Ứng dụng không lưu thông tin người ủng hộ. Tiền đi thẳng từ tài khoản của bạn tới tài khoản nhận, không qua bên trung gian nào.",
};

export const privacy = {
  h1: "Riêng tư",
  lede: "Nguyên tắc: nội dung bạn gõ không rời khỏi máy và không được ghi xuống ổ đĩa, trừ một trường hợp do chính bạn bắt đầu (bản ghi thao tác gõ để báo lỗi, mô tả bên dưới). Lưu lượng mạng tự động duy nhất của ứng dụng là kiểm tra cập nhật.",
  updated: "Cập nhật lần cuối: 13/11/2026. Trang này được lưu cùng mã nguồn; mọi điểm kết nối mạng mới phải được ghi vào đây trước khi phát hành.",
  // The "Trang web" analytics line: `off` when site/config.json has no analytics, `umami` when it configures the
  // self-hosted Umami (Q7, ADR 0602 amendment). {{analyticsOrigin}} is the configured script origin.
  analytics: {
    off: "<strong>Phân tích truy cập: không có.</strong> Không Google Analytics, không công cụ đo lường của bên thứ ba, không pixel theo dõi.",
    umami: "<strong>Phân tích truy cập: Umami, do dự án tự vận hành.</strong> Các trang của trang web này (không phải ứng dụng, không phải trang ghi chú phát hành) tải mã của Umami từ <code>{{analyticsOrigin}}</code>, một máy chủ do chính dự án vận hành, và gửi tới đó lượt xem trang: địa chỉ trang, tiêu đề trang, trang dẫn tới, kích thước màn hình và ngôn ngữ của trình duyệt. Umami không dùng cookie và không lưu gì trong trình duyệt của bạn; dự án không thu thập dữ liệu cá nhân và không lập hồ sơ người dùng. Để đếm số người xem, máy chủ tạo một mã lượt truy cập bằng cách băm một chiều địa chỉ IP và trình duyệt của bạn cùng một giá trị đổi mỗi tháng; địa chỉ IP không được lưu, chỉ lưu quốc gia và thành phố ước tính từ địa chỉ đó cùng loại trình duyệt, hệ điều hành và thiết bị. Nếu trình duyệt của bạn bật Do Not Track, không có gì được gửi đi. Dự án chỉ xem số liệu tổng hợp (theo trang, nguồn truy cập và quốc gia); dữ liệu không được chia sẻ với ai và không có quảng cáo.",
  },
  html: `
<h2 id="tom-tat">Tóm tắt</h2>
<ul>
  <li>Không telemetry, không dịch vụ phân tích, không SDK báo cáo sự cố, không cấu hình hay quy tắc tải từ xa.</li>
  <li>Không có cửa sổ web tải nội dung từ xa. Ghi chú phát hành hiện mà không tải tài nguyên ngoài.</li>
  <li>Ô mật khẩu và chế độ nhập bảo mật của macOS luôn được bỏ qua. Đây không phải là cài đặt.</li>
  <li>Chỉ cần một quyền: Trợ năng (macOS 12 tới 26) hoặc Điều khiển thiết bị và truy cập dữ liệu (macOS 27). Nếu macOS đòi thêm, ứng dụng nói rõ lý do. Không có quyền Ghi màn hình, Automation hay Toàn quyền truy cập ổ đĩa.</li>
  <li>Khi thiếu quyền, bàn phím của bạn vẫn gõ bình thường (ứng dụng nhả phím ra, không giữ lại).</li>
</ul>

<h2 id="luu-tren-may">Ứng dụng lưu gì trên máy bạn</h2>
<div class="table-wrap"><table>
<thead><tr><th scope="col">Dữ liệu</th><th scope="col">Nơi lưu</th><th scope="col">Ghi chú</th></tr></thead>
<tbody>
<tr><th scope="row">Cài đặt, quy tắc theo ứng dụng, chế độ Việt/Anh theo ứng dụng, gõ tắt</th><td><code>~/Library/Application Support/{{AppName}}/</code></td><td>Chỉ lưu những lựa chọn bạn tự đặt. Thư mục chỉ mình bạn đọc được. Gõ tắt là nội dung do bạn viết, có thể chứa chữ riêng tư.</td></tr>
<tr><th scope="row">Bản sao lưu cài đặt</th><td><code>~/Library/Application Support/{{AppName}}/backups/</code></td><td>Giữ 5 bản gần nhất để khôi phục khi file bị hỏng.</td></tr>
<tr><th scope="row">Nhật ký sức khỏe ứng dụng</th><td><code>~/Library/Logs/{{AppName}}/</code></td><td>Chỉ có sự kiện không chứa nội dung (loại phím, mã kết quả, thời gian). Tối đa 5 file, mỗi file 1 MB, giữ 14 ngày.</td></tr>
<tr><th scope="row">Bản ghi thao tác gõ (chỉ khi bạn bấm bắt đầu)</th><td><code>~/Library/Logs/{{AppName}}/captures/</code></td><td>Xem mục bên dưới. Tự xóa sau 24 giờ, không nằm trong bản sao lưu Time Machine.</td></tr>
<tr><th scope="row">Trạng thái cập nhật (Sparkle)</th><td><code>~/Library/Preferences/{{bundleId}}.plist</code> và <code>~/Library/Caches/{{bundleId}}/</code></td><td>Do hệ thống quản lý theo mặc định.</td></tr>
</tbody></table></div>
<p>Mọi file ghi bằng cách ghi an toàn (ghi file tạm rồi đổi tên) để cập nhật hay mất điện không làm hỏng cài đặt. Đường dẫn đầy đủ để xóa nằm ở mục "Xóa dữ liệu" bên dưới.</p>

<h2 id="gui-di">Ứng dụng gửi gì đi</h2>
<p>Chỉ một thứ: <strong>kiểm tra cập nhật</strong>, mỗi 24 giờ (bạn tắt được trong Cài đặt).</p>
<ul>
  <li>Ứng dụng tải <code>https://{{host}}/appcast.xml</code> qua HTTPS, rồi tải bản cập nhật từ cùng máy chủ khi bạn đồng ý hoặc khi cập nhật tự động đang bật. {{verifyHtml}} Nếu bản cập nhật cũng được lưu ở GitHub Releases, trang này sẽ ghi rõ.</li>
  <li>Như mọi yêu cầu web, máy chủ thấy địa chỉ IP của bạn và tên cùng phiên bản ứng dụng. Ứng dụng không gửi hồ sơ cấu hình hệ thống (tính năng này của Sparkle bị tắt).</li>
  <li>Bản cập nhật phải mang chữ ký EdDSA hợp lệ, nếu không ứng dụng từ chối cài.</li>
  <li>Ngoài ra không có yêu cầu mạng nào khác. Có kiểm tra tự động trong quy trình phát hành để bảo đảm file chạy chỉ chứa các địa chỉ máy chủ đã khai báo.</li>
</ul>

<h2 id="chan-doan">Dữ liệu chẩn đoán gồm gì, không gồm gì</h2>
<p>Khi bạn bấm <em>Báo lỗi...</em>, ứng dụng tạo một báo cáo văn bản và cho bạn xem <strong>đúng nội dung sẽ gửi</strong> trước khi sao chép hay lưu. Báo cáo không bao giờ được gửi tự động.</p>
<h3>Có trong báo cáo</h3>
<ul>
  <li>Phiên bản và bản dựng ứng dụng, kênh cập nhật.</li>
  <li>Phiên bản macOS, loại máy (Apple silicon hoặc Intel), bố cục bàn phím, các nguồn nhập đang bật (chỉ mã định danh).</li>
  <li>Trạng thái các quyền, trạng thái Secure Input và ứng dụng có thể đang giữ nó.</li>
  <li>Ứng dụng đang gõ (mã định danh và phiên bản), quy tắc tương thích đang áp dụng.</li>
  <li>Cài đặt không chứa nội dung (kiểu gõ, các công tắc), thống kê thời gian xử lý, 50 sự kiện sức khỏe gần nhất, các bộ gõ khác đang chạy.</li>
  <li>Loại phím gần đây (chữ cái, chữ số, xóa lùi, phím bổ trợ), không bao giờ là giá trị phím.</li>
</ul>
<h3>Không bao giờ có trong báo cáo</h3>
<ul>
  <li>Chữ bạn đã gõ, từ, giá trị của ô nhập, nội dung bảng nhớ tạm (clipboard).</li>
  <li>Tiêu đề cửa sổ, địa chỉ trang web, đường dẫn file trong thư mục cá nhân của bạn (ngoài thư mục riêng của {{AppName}}).</li>
  <li>Nội dung gõ tắt (chỉ ghi số lượng).</li>
  <li>Danh sách chế độ theo ứng dụng của bạn, trừ mục của đúng ứng dụng bạn đang báo lỗi.</li>
</ul>

<h2 id="ban-ghi">Bản ghi thao tác gõ (tùy chọn, do bạn bắt đầu)</h2>
<p>Đây là trường hợp duy nhất chữ bạn gõ chạm tới ổ đĩa, và bạn thấy rõ lúc nó diễn ra. Nó giúp tái hiện lỗi khó mà báo cáo thường không đủ.</p>
<ul>
  <li>Chỉ bắt đầu khi bạn chủ động bấm trong cửa sổ Chẩn đoán và xác nhận.</li>
  <li>Mặc định 60 giây, tối đa 180 giây, rồi tự dừng. Suốt thời gian đó có biểu tượng thanh menu khác và một bảng đếm ngược kèm nút Dừng.</li>
  <li>Không ghi gì khi macOS đang ở chế độ nhập bảo mật hoặc khi ô mật khẩu đang được chọn.</li>
  <li>Lưu cục bộ, không nằm trong sao lưu, tự xóa sau 24 giờ hoặc ngay khi bạn xuất hay hủy. Bạn xem được bản đọc được trước khi chia sẻ. Không bao giờ tự tải lên.</li>
</ul>

<h2 id="clipboard">Bảng nhớ tạm (clipboard)</h2>
<p>Ứng dụng chỉ ghi vào bảng nhớ tạm khi bạn bấm <em>Mở GitHub</em> trong cửa sổ báo lỗi (để dán báo cáo vào GitHub), và cửa sổ nói rõ điều đó trước khi ghi. Ngoại lệ còn lại là chế độ tương thích "dán" mà bạn tự bật cho một ứng dụng cụ thể; chế độ này lưu rồi khôi phục bảng nhớ tạm quanh mỗi lần dán và được giải thích khi bạn bật.</p>

<h2 id="trang-web">Trang web</h2>
<ul>
  <li>{{analyticsHtml}}</li>
  <li>Không cookie, không bộ nhớ cục bộ để theo dõi. Phông chữ là phông có sẵn trên máy bạn; mã, hình ảnh, bản cập nhật và file cài đặt (DMG) đều phục vụ từ chính máy chủ của trang này.</li>
  <li>Máy chủ web ghi mỗi yêu cầu chỉ với thời điểm, phương thức, đường dẫn (không có phần truy vấn), mã kết quả và kích thước; không ghi địa chỉ IP, trình duyệt hay trang dẫn tới. Từ nhật ký này, mỗi ngày chúng tôi đếm số yêu cầu tới <code>appcast.xml</code> để ước lượng số máy đang dùng, và số lượt tải từng file; chỉ giữ con số tổng theo ngày.</li>
  <li>Kết nối đi qua Cloudflare và bộ định tuyến của máy chủ trước khi tới máy chủ web; như mọi trang web, các lớp này thấy địa chỉ IP của bạn trong lúc xử lý yêu cầu. {{verifyHtml}} Xác minh thời gian lưu nhật ký của hai lớp này trước khi công bố.</li>
  <li>Số lượt cài qua Homebrew lấy từ bộ đếm công khai của Homebrew.</li>
</ul>

<h2 id="gop-y">Báo lỗi và hỗ trợ</h2>
<p>Khi bạn mở một issue trên GitHub hoặc gửi email, nội dung bạn viết do bạn quyết định và tuân theo chính sách của GitHub hoặc nhà cung cấp email của bạn. {{AppName}} không tự gửi những gì bạn đã gõ.</p>

<h2 id="ung-ho">Ủng hộ</h2>
<p>Ứng dụng không lưu hay gửi thông tin người ủng hộ. Việc chuyển tiền diễn ra giữa bạn và ngân hàng của bạn hoặc GitHub, theo chính sách riêng của họ.</p>

<h2 id="xoa-du-lieu">Xóa dữ liệu</h2>
<p>Thoát {{AppName}}, kéo ứng dụng vào Thùng rác, rồi xóa các thư mục trong bảng ở trên. Nếu cài bằng Homebrew, một lệnh làm hết:</p>
<pre><code>brew uninstall --cask --zap {{slug}}</code></pre>
`,
};
