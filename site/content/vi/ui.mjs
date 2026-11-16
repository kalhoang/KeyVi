// SPDX-License-Identifier: GPL-3.0-or-later
// Vietnamese UI strings shared by every page. Standard, neutral Vietnamese addressed to "bạn" (PRD-R62).
// {{AppName}}, {{slug}}, {{host}} are replaced at build time from scripts/brand.env. {{AppNameTM}} adds the trademark
// sign: titles and prose only, never buttons or navigation (spec/03-product.md, trademark sign).
export default {
  lang: "vi",
  siteTagline: "Bộ gõ tiếng Việt cho Mac",
  skipLink: "Chuyển đến nội dung",
  notice: { label: "Thông báo", link: "Xem chi tiết" },
  navLabel: "Điều hướng chính",
  nav: { features: "Tính năng", compat: "Tương thích", support: "Hỗ trợ", downloadCta: "Tải về", privacy: "Riêng tư", changelog: "Nhật ký thay đổi" },
  langSwitch: { text: "English", title: "Read this page in English", lang: "en" },
  footer: {
    promise: "Không cookie, không theo dõi, không phông chữ hay mã từ bên thứ ba.",
    byline: "Dự án cá nhân của Kal.",
    donate: "Ủng hộ",
    repo: "Mã nguồn",
    appcast: "Nguồn cập nhật (appcast)",
    language: "Ngôn ngữ",
  },
  titles: {
    home: "{{AppNameTM}}: bộ gõ tiếng Việt cho Mac",
    download: "Tải về",
    compat: "Ứng dụng tương thích",
    changelog: "Nhật ký thay đổi",
    privacy: "Riêng tư",
    support: "Hỗ trợ",
    donate: "Ủng hộ",
    notFound: "Không tìm thấy trang",
  },
  descriptions: {
    home: "{{AppNameTM}} là bộ gõ tiếng Việt cho macOS: mặc định hợp lý, từ tiếng Anh tự giữ nguyên, không thu thập dữ liệu, miễn phí.",
    download: "Tải {{AppNameTM}} cho macOS: bản ổn định, bản beta, mã SHA-256, yêu cầu hệ thống và cài bằng Homebrew.",
    compat: "Danh sách ứng dụng đã kiểm tra với {{AppNameTM}}, kèm trạng thái, ghi chú và ngày kiểm tra gần nhất.",
    changelog: "Những thay đổi người dùng nhìn thấy trong từng bản phát hành của {{AppNameTM}}.",
    privacy: "Mọi thứ {{AppNameTM}} lưu và gửi đi, dữ liệu chẩn đoán gồm gì, và chính sách phân tích của trang web.",
    support: "Câu hỏi thường gặp, cách xử lý theo triệu chứng, cách báo lỗi và hướng dẫn chuyển từ bộ gõ khác sang {{AppNameTM}}.",
    donate: "{{AppNameTM}} miễn phí. Đây là cách ủng hộ nếu bạn thấy có ích.",
  },
  status: {
    works: { label: "Hoạt động tốt", help: "Đã kiểm tra trên một phiên bản gần đây." },
    worksWithNotes: { label: "Hoạt động, có lưu ý", help: "Dùng được, kèm một ghi chú ngắn." },
    notVerified: { label: "Chưa kiểm tra", help: "Chưa có kết quả kiểm tra, hoặc kết quả đã quá 120 ngày." },
    knownLimitation: { label: "Hạn chế đã biết", help: "Có giới hạn đã biết, kèm giải thích và cách xử lý." },
  },
  categories: {
    browser: "Trình duyệt", office: "Văn phòng", chat: "Trò chuyện", developer: "Soạn thảo và lập trình",
    terminal: "Terminal", design: "Thiết kế", launcher: "Công cụ gọi nhanh", remote: "Máy tính từ xa",
    system: "Hệ thống", game: "Trò chơi", notes: "Ứng dụng ghi chú", other: "Khác",
  },
  channel: { stable: "Ổn định", beta: "Beta" },
  common: {
    version: "Phiên bản", date: "Ngày", channel: "Kênh", download: "Tải về", sha256: "SHA-256",
    minMacos: "Yêu cầu tối thiểu", macosAtLeast: "macOS {{v}} trở lên",
    noRelease: "Chưa có bản phát hành",
    noReleaseDetail: "Bản đầu tiên đang được phát triển. Khi có bản phát hành, phiên bản và liên kết tải sẽ hiện ở đây.",
    verifyTitle: "Cần xác minh trước khi công bố",
    sampleDataNotice: "Đây là dữ liệu mẫu, chưa phải kết quả kiểm tra thật. Mọi ứng dụng đều ghi \"Chưa kiểm tra\".",
    lastUpdated: "Cập nhật lần cuối",
    backToTop: "Lên đầu trang",
    external: "(mở trang ngoài)",
  },
  notFound: {
    heading: "Không tìm thấy trang này",
    body: "Địa chỉ có thể đã đổi hoặc bị gõ sai. Bạn có thể về trang chủ hoặc xem phần hỗ trợ.",
    home: "Về trang chủ",
    support: "Xem phần hỗ trợ",
  },
};
