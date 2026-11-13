// SPDX-License-Identifier: LicenseRef-App-Pending
// Vietnamese page copy: home, download, compatibility, changelog, privacy, donate.
// Drafts from spec/03-product.md are reused verbatim where they exist (PRD-R40, PRD-R59).
// Trusted HTML; tokens like {{AppName}} are filled at build time. Standard Vietnamese, addressed to "bạn".

export const home = {
  h1: "Gõ tiếng Việt đúng ngay từ đầu, ở mọi ứng dụng trên Mac.",
  lede: "Bộ gõ tiếng Việt cho Mac. Cài đặt chỉ mất khoảng một phút, sau đó bạn cứ gõ như bình thường.",
  footnote: "{{AppName}} không gửi nội dung bạn gõ đi đâu cả và không lưu lại những gì bạn gõ.",
  typedLabel: "Ví dụ gõ Telex",
  typed: [
    { keys: "tieengs Vieetj", out: "tiếng Việt" },
    { keys: "text user wifi", out: "text user wifi" },
  ],
  typedCaption: "Từ tiếng Anh được giữ nguyên, bạn không cần chuyển chế độ.",
  demoPlaceholder: "Video 20 giây đang được chuẩn bị",
  demoCaption: "Gõ Telex, tự khôi phục từ tiếng Anh, chuyển chế độ theo từng ứng dụng.",
  demoAlt: "Video minh hoạ 20 giây về cách gõ tiếng Việt với {{AppName}}",
  downloadBtn: "Tải {{AppName}} {{version}}",
  downloadSub: "{{requirement}}",
  noReleaseBtn: "Chưa có bản phát hành",
  preRelease: "Trạng thái: đang phát triển, chưa phát hành công khai.",
  brewLabel: "Hoặc cài bằng Homebrew",
  allDownloads: "Tất cả bản tải và mã SHA-256",
  proofHeading: "Ba điều bạn có thể kiểm chứng",
  proof: [
    { h: "Không thu thập dữ liệu", p: "Không telemetry, không SDK phân tích, không \"dữ liệu sử dụng ẩn danh\". Lưu lượng mạng tự động duy nhất là kiểm tra cập nhật.", link: "{{hrefPrivacy}}", linkText: "Xem chi tiết về riêng tư" },
    { h: "Miễn phí", p: "{{AppName}} miễn phí và sẽ luôn miễn phí. Không có tính năng nào bị khoá, không có nhắc nhở ủng hộ trong ứng dụng." },
    { h: "Bộ máy gõ mã nguồn mở", p: "Phần xử lý tiếng Việt là một gói Swift theo Giấy phép Công cộng Mozilla 2.0 (MPL-2.0), viết từ đầu theo quy tắc chính tả tiếng Việt và có bộ kiểm thử riêng.", link: "{{repo}}", linkText: "Xem mã nguồn", external: true },
  ],
  whyHeading: "Những điều bạn sẽ thấy khác",
  why: [
    "Từ tiếng Anh như <code>text</code>, <code>user</code>, <code>wifi</code> tự giữ nguyên, kể cả khi bạn kết thúc từ bằng dấu phẩy, dấu chấm hay phím Enter.",
    "Tiếng lóng như <em>dzô</em>, <em>hẹo</em> gõ được bình thường, vì tính hợp lệ dựa trên quy tắc chính tả chứ không dựa trên từ điển.",
    "Khi macOS chặn mọi bộ gõ (Secure Input), {{AppName}} nói rõ ứng dụng nào đang giữ và cách tắt. {{AppName}} không tự đoán là bạn đang gõ mật khẩu.",
    "Gõ dấu ở cuối từ vẫn đúng: <code>vietj</code>, <code>tieengs</code>, <code>dangd</code>.",
    "Nhớ chế độ Việt hoặc Anh cho từng ứng dụng: Terminal luôn tiếng Anh, Zalo luôn tiếng Việt.",
  ],
  compatHeading: "Ứng dụng của bạn có chạy tốt không?",
  compatText: "Mỗi ứng dụng được kiểm tra theo một quy trình cố định và ghi rõ ngày kiểm tra.",
  compatLink: "Xem danh sách ứng dụng tương thích",
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
    "Mở tệp DMG và kéo {{AppName}} vào thư mục Applications.",
    "Mở {{AppName}} từ thư mục Applications, không chạy trực tiếp từ DMG.",
    "Làm theo hướng dẫn trên màn hình để cấp quyền. Cả quá trình chỉ mất khoảng một phút.",
  ],
  reqHeading: "Yêu cầu hệ thống",
  reqMacos: "{{macosRequirement}}",
  reqArch: "Máy Mac dùng chip Apple silicon hoặc Intel (một bản chạy cho cả hai). macOS 27 chỉ chạy trên Apple silicon.",
  reqExcluded: "Máy Mac chỉ lên được tới macOS Sonoma (ví dụ MacBook Air 2018 và 2019, một số máy 2017) chưa được hỗ trợ.",
  reqPermission: "Quyền cần cấp: <strong>Trợ năng</strong> trên macOS 15 và 26, <strong>Điều khiển thiết bị và truy cập dữ liệu</strong> trên macOS 27. {{verifyHtml}} Tên mục trong macOS tiếng Việt cần được xác minh trên từng phiên bản.",
  reqNoOthers: "{{AppName}} không xin quyền nào khác (không Ghi màn hình, không Toàn quyền truy cập ổ đĩa).",
  trustHeading: "Chữ ký và công chứng",
  trustBody: "Mỗi bản DMG được ký bằng chứng chỉ Developer ID của Kal, được Apple công chứng (notarize) và đính kèm vé công chứng (staple), nên macOS mở được mà không cảnh báo. Cập nhật tự động dùng Sparkle 2 và được ký EdDSA; ứng dụng từ chối bản cập nhật sai chữ ký.",
  verifyHeading: "Tự kiểm tra tệp đã tải",
  verifyBody: "So mã SHA-256 của tệp với mã ghi ở trên, rồi kiểm tra chữ ký sau khi cài:",
  verifyHashCmd: "shasum -a 256 &lt;đường dẫn tới tệp DMG&gt;",
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
  promise: "Ủng hộ chỉ là tấm lòng. Không có tính năng nào bị khoá, và ứng dụng không bao giờ hiện lời nhắc ủng hộ.",
  vietqr: { h: "VietQR (Napas)", alt: "Mã QR VietQR tới tài khoản ngân hàng của Kal (ảnh giữ chỗ)", accountLabel: "Tên tài khoản", bankLabel: "Ngân hàng", accountValue: "Tên chủ tài khoản sẽ được ghi ở đây", bankValue: "Ngân hàng sẽ được ghi ở đây", how: "Mở ứng dụng ngân hàng, chọn quét mã QR và kiểm tra tên tài khoản hiện ra trước khi xác nhận." },
  momo: { h: "MoMo", alt: "Mã QR MoMo của Kal (ảnh giữ chỗ)", how: "Mở MoMo, chọn Quét mã và kiểm tra tên người nhận trước khi xác nhận." },
  sponsors: { h: "GitHub Sponsors", body: "Nếu bạn dùng GitHub, có thể ủng hộ định kỳ hoặc một lần.", link: "Mở trang GitHub Sponsors" },
  placeholderNote: "Ảnh QR và thông tin tài khoản là chỗ giữ trước, sẽ được thay bằng thông tin thật đã xác nhận với Kal trước bản công bố đầu tiên.",
  privacy: "Ứng dụng không lưu thông tin người ủng hộ. Việc chuyển tiền diễn ra hoàn toàn giữa bạn và ngân hàng, MoMo hoặc GitHub.",
};

export const privacy = {
  h1: "Riêng tư",
  lede: "Nguyên tắc: nội dung bạn gõ không rời khỏi máy và không được ghi xuống ổ đĩa, trừ một trường hợp do chính bạn bắt đầu (bản ghi thao tác gõ để báo lỗi, mô tả bên dưới). Lưu lượng mạng tự động duy nhất của ứng dụng là kiểm tra cập nhật.",
  updated: "Cập nhật lần cuối: 13/11/2026. Trang này được lưu cùng mã nguồn; mọi điểm kết nối mạng mới phải được ghi vào đây trước khi phát hành.",
  // The "Trang web" analytics line: `off` when site/config.json has no PostHog key, `posthog` when it has one.
  analytics: {
    off: "<strong>Phân tích truy cập: không có.</strong> Không Google Analytics, không công cụ đo lường của bên thứ ba, không pixel theo dõi.",
    posthog: "<strong>Phân tích truy cập: PostHog Cloud ở chế độ không cookie.</strong> Các trang của trang web này (không phải ứng dụng, không phải trang ghi chú phát hành) tải thư viện đo lường của PostHog từ <code>{{analyticsAssets}}</code> và gửi lượt xem trang tới <code>{{analyticsHost}}</code>. Không cookie, không lưu gì trong trình duyệt, không ghi lại phiên, không ghi thao tác bấm, không hồ sơ người dùng. Để đếm số người xem mà không nhận diện bạn, PostHog tính một mã băm từ địa chỉ IP và trình duyệt cùng một giá trị đổi mỗi ngày; địa chỉ IP không được lưu. Không có quảng cáo hay bên thứ ba nào khác.",
  },
  html: `
<h2 id="tom-tat">Tóm tắt</h2>
<ul>
  <li>Không telemetry, không dịch vụ phân tích, không SDK báo cáo sự cố, không cấu hình hay quy tắc tải từ xa.</li>
  <li>Không có cửa sổ web tải nội dung từ xa. Ghi chú phát hành hiện mà không tải tài nguyên ngoài.</li>
  <li>Ô mật khẩu và chế độ nhập bảo mật của macOS luôn được bỏ qua. Đây không phải là cài đặt.</li>
  <li>Chỉ cần một quyền: Trợ năng (macOS 15 và 26) hoặc Điều khiển thiết bị và truy cập dữ liệu (macOS 27). Nếu macOS đòi thêm, ứng dụng nói rõ lý do. Không có quyền Ghi màn hình, Automation hay Toàn quyền truy cập ổ đĩa.</li>
  <li>Khi thiếu quyền, bàn phím của bạn vẫn gõ bình thường (ứng dụng nhả phím ra, không giữ lại).</li>
</ul>

<h2 id="luu-tren-may">Ứng dụng lưu gì trên máy bạn</h2>
<div class="table-wrap"><table>
<thead><tr><th scope="col">Dữ liệu</th><th scope="col">Nơi lưu</th><th scope="col">Ghi chú</th></tr></thead>
<tbody>
<tr><th scope="row">Cài đặt, quy tắc theo ứng dụng, chế độ Việt/Anh theo ứng dụng, gõ tắt</th><td><code>~/Library/Application Support/{{AppName}}/</code></td><td>Chỉ lưu những lựa chọn bạn tự đặt. Thư mục chỉ mình bạn đọc được. Gõ tắt là nội dung do bạn viết, có thể chứa chữ riêng tư.</td></tr>
<tr><th scope="row">Bản sao lưu cài đặt</th><td><code>~/Library/Application Support/{{AppName}}/backups/</code></td><td>Giữ 5 bản gần nhất để khôi phục khi tệp bị hỏng.</td></tr>
<tr><th scope="row">Nhật ký sức khoẻ ứng dụng</th><td><code>~/Library/Logs/{{AppName}}/</code></td><td>Chỉ có sự kiện không chứa nội dung (loại phím, mã kết quả, thời gian). Tối đa 5 tệp, mỗi tệp 1 MB, giữ 14 ngày.</td></tr>
<tr><th scope="row">Bản ghi thao tác gõ (chỉ khi bạn bấm bắt đầu)</th><td><code>~/Library/Logs/{{AppName}}/captures/</code></td><td>Xem mục bên dưới. Tự xoá sau 24 giờ, không nằm trong bản sao lưu Time Machine.</td></tr>
<tr><th scope="row">Trạng thái cập nhật (Sparkle)</th><td><code>~/Library/Preferences/{{bundleId}}.plist</code> và <code>~/Library/Caches/{{bundleId}}/</code></td><td>Do hệ thống quản lý theo mặc định.</td></tr>
</tbody></table></div>
<p>Mọi tệp ghi bằng cách ghi an toàn (ghi tệp tạm rồi đổi tên) để cập nhật hay mất điện không làm hỏng cài đặt. Đường dẫn đầy đủ để xoá nằm ở mục "Xoá dữ liệu" bên dưới.</p>

<h2 id="gui-di">Ứng dụng gửi gì đi</h2>
<p>Chỉ một thứ: <strong>kiểm tra cập nhật</strong>, mỗi 24 giờ (bạn tắt được trong Cài đặt).</p>
<ul>
  <li>Ứng dụng tải <code>https://{{host}}/appcast.xml</code> qua HTTPS, rồi tải bản cập nhật từ cùng máy chủ khi bạn đồng ý hoặc khi cập nhật tự động đang bật. {{verifyHtml}} Nếu bản cập nhật cũng được lưu ở GitHub Releases, trang này sẽ ghi rõ.</li>
  <li>Như mọi yêu cầu web, máy chủ thấy địa chỉ IP của bạn và tên cùng phiên bản ứng dụng. Ứng dụng không gửi hồ sơ cấu hình hệ thống (tính năng này của Sparkle bị tắt).</li>
  <li>Bản cập nhật phải mang chữ ký EdDSA hợp lệ, nếu không ứng dụng từ chối cài.</li>
  <li>Ngoài ra không có yêu cầu mạng nào khác. Có kiểm tra tự động trong quy trình phát hành để bảo đảm tệp chạy chỉ chứa các địa chỉ máy chủ đã khai báo.</li>
</ul>

<h2 id="chan-doan">Dữ liệu chẩn đoán gồm gì, không gồm gì</h2>
<p>Khi bạn bấm <em>Báo lỗi...</em>, ứng dụng tạo một báo cáo văn bản và cho bạn xem <strong>đúng nội dung sẽ gửi</strong> trước khi sao chép hay lưu. Báo cáo không bao giờ được gửi tự động.</p>
<h3>Có trong báo cáo</h3>
<ul>
  <li>Phiên bản và bản dựng ứng dụng, kênh cập nhật.</li>
  <li>Phiên bản macOS, loại máy (Apple silicon hoặc Intel), bố cục bàn phím, các nguồn nhập đang bật (chỉ mã định danh).</li>
  <li>Trạng thái các quyền, trạng thái Secure Input và ứng dụng có thể đang giữ nó.</li>
  <li>Ứng dụng đang gõ (mã định danh và phiên bản), quy tắc tương thích đang áp dụng.</li>
  <li>Cài đặt không chứa nội dung (kiểu gõ, các công tắc), thống kê thời gian xử lý, 50 sự kiện sức khoẻ gần nhất, các bộ gõ khác đang chạy.</li>
  <li>Loại phím gần đây (chữ cái, chữ số, xoá lùi, phím bổ trợ), không bao giờ là giá trị phím.</li>
</ul>
<h3>Không bao giờ có trong báo cáo</h3>
<ul>
  <li>Chữ bạn đã gõ, từ, giá trị của ô nhập, nội dung bảng nhớ tạm (clipboard).</li>
  <li>Tiêu đề cửa sổ, địa chỉ trang web, đường dẫn tệp trong thư mục cá nhân của bạn (ngoài thư mục riêng của {{AppName}}).</li>
  <li>Nội dung gõ tắt (chỉ ghi số lượng).</li>
  <li>Danh sách chế độ theo ứng dụng của bạn, trừ mục của đúng ứng dụng bạn đang báo lỗi.</li>
</ul>

<h2 id="ban-ghi">Bản ghi thao tác gõ (tuỳ chọn, do bạn bắt đầu)</h2>
<p>Đây là trường hợp duy nhất chữ bạn gõ chạm tới ổ đĩa, và bạn thấy rõ lúc nó diễn ra. Nó giúp tái hiện lỗi khó mà báo cáo thường không đủ.</p>
<ul>
  <li>Chỉ bắt đầu khi bạn chủ động bấm trong cửa sổ Chẩn đoán và xác nhận.</li>
  <li>Mặc định 60 giây, tối đa 180 giây, rồi tự dừng. Suốt thời gian đó có biểu tượng thanh menu khác và một bảng đếm ngược kèm nút Dừng.</li>
  <li>Không ghi gì khi macOS đang ở chế độ nhập bảo mật hoặc khi ô mật khẩu đang được chọn.</li>
  <li>Lưu cục bộ, không nằm trong sao lưu, tự xoá sau 24 giờ hoặc ngay khi bạn xuất hay huỷ. Bạn xem được bản đọc được trước khi chia sẻ. Không bao giờ tự tải lên.</li>
</ul>

<h2 id="clipboard">Bảng nhớ tạm (clipboard)</h2>
<p>Ứng dụng chỉ ghi vào bảng nhớ tạm khi bạn bấm <em>Mở GitHub</em> trong cửa sổ báo lỗi (để dán báo cáo vào GitHub), và cửa sổ nói rõ điều đó trước khi ghi. Ngoại lệ còn lại là chế độ tương thích "dán" mà bạn tự bật cho một ứng dụng cụ thể; chế độ này lưu rồi khôi phục bảng nhớ tạm quanh mỗi lần dán và được giải thích khi bạn bật.</p>

<h2 id="trang-web">Trang web</h2>
<ul>
  <li>{{analyticsHtml}}</li>
  <li>Không cookie, không bộ nhớ cục bộ để theo dõi. Phông chữ là phông có sẵn trên máy bạn; mã, hình ảnh, bản cập nhật và tệp cài đặt (DMG) đều phục vụ từ chính máy chủ của trang này.</li>
  <li>Máy chủ web ghi mỗi yêu cầu chỉ với thời điểm, phương thức, đường dẫn (không có phần truy vấn), mã kết quả và kích thước; không ghi địa chỉ IP, trình duyệt hay trang dẫn tới. Từ nhật ký này, mỗi ngày chúng tôi đếm số yêu cầu tới <code>appcast.xml</code> để ước lượng số máy đang dùng, và số lượt tải từng tệp; chỉ giữ con số tổng theo ngày.</li>
  <li>Kết nối đi qua Cloudflare và bộ định tuyến của máy chủ trước khi tới máy chủ web; như mọi trang web, các lớp này thấy địa chỉ IP của bạn trong lúc xử lý yêu cầu. {{verifyHtml}} Xác minh thời gian lưu nhật ký của hai lớp này trước khi công bố.</li>
  <li>Số lượt cài qua Homebrew lấy từ bộ đếm công khai của Homebrew.</li>
</ul>

<h2 id="gop-y">Báo lỗi và hỗ trợ</h2>
<p>Khi bạn mở một issue trên GitHub hoặc gửi email, nội dung bạn viết do bạn quyết định và tuân theo chính sách của GitHub hoặc nhà cung cấp email của bạn. {{AppName}} không tự gửi những gì bạn đã gõ.</p>

<h2 id="ung-ho">Ủng hộ</h2>
<p>Ứng dụng không lưu hay gửi thông tin người ủng hộ. Việc chuyển tiền diễn ra giữa bạn và ngân hàng của bạn hoặc GitHub, theo chính sách riêng của họ.</p>

<h2 id="xoa-du-lieu">Xoá dữ liệu</h2>
<p>Thoát {{AppName}}, kéo ứng dụng vào Thùng rác, rồi xoá các thư mục trong bảng ở trên. Nếu cài bằng Homebrew, một lệnh làm hết:</p>
<pre><code>brew uninstall --cask --zap {{slug}}</code></pre>
`,
};
