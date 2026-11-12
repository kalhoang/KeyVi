# {{AppName}}

[English](README.md)

{{AppName}} là bộ gõ tiếng Việt cho macOS do Kal tự viết từ đầu. Đây là ứng dụng nằm trên thanh menu, gõ tiếng Việt (Telex hoặc VNI) trong mọi ứng dụng, tự khôi phục từ tiếng Anh, và nói rõ cho bạn biết khi có điều gì đó không hoạt động được.

> **Về tên:** "{{AppName}}" là tên hiển thị khai báo trong [`Config/Brand.xcconfig`](Config/Brand.xcconfig) và [`scripts/brand.env`](scripts/brand.env). Tên sản phẩm hiện là tên tạm, chưa được chọn. Xem [docs/decisions/0400-documentation-decisions.md](docs/decisions/0400-documentation-decisions.md).

## Tình trạng

**Giai đoạn pre-alpha. Hiện chưa có bản tải công khai.**

Mốc đầu tiên là bản alpha riêng tư (Kal cùng tối đa 10 người thử được mời). Bản này chỉ bắt đầu khi bộ kiểm thử của engine đạt, fuzzing sạch và phần hướng dẫn ban đầu dùng được, đồng thời mọi bài kiểm thử P0 đều phải đạt (PRD-R0). Ba mục P0 là lý do dự án này tồn tại:

1. Gõ không bao giờ bị chặn "ngẫu nhiên": ứng dụng chỉ tạm dừng khi hệ điều hành báo chế độ nhập bảo mật hoặc khi ô đang gõ thật sự là ô mật khẩu, và cho bạn biết ứng dụng nào đang giữ chế độ đó.
2. Gõ được tiếng lóng như `dzô` và `hẹo`: tính hợp lệ dựa trên quy tắc chính tả tiếng Việt, không dựa vào từ điển.
3. Tự quay về tiếng Anh hoạt động với mọi phím kết thúc từ (dấu câu, Return, Tab), không chỉ phím Space.

Lộ trình (alpha riêng tư, beta kín, beta công khai, 1.0) cùng tiêu chí vào và ra của từng giai đoạn nằm ở [spec/03-product.md](spec/03-product.md) mục 3.3. README này không nêu điều gì vượt ra ngoài bản đặc tả.

## Đây là gì

- Gõ Telex và VNI, kết quả theo Unicode (NFC).
- Tự khôi phục từ tiếng Anh bằng dữ liệu đi kèm, không cần tải thêm.
- Nhớ chế độ Việt/Anh theo từng ứng dụng và quy tắc riêng cho từng ứng dụng.
- Gõ tắt (macro).
- Biểu tượng trạng thái trên thanh menu, hướng dẫn ban đầu có ô gõ thử, cửa sổ Cài đặt gọn.
- Chẩn đoán và báo lỗi một chạm, không bao giờ chứa nội dung bạn đã gõ.
- Cập nhật qua Sparkle 2, có kênh ổn định và kênh beta.
- Giao diện tiếng Việt và tiếng Anh.

Phạm vi đầy đủ và danh sách những thứ cố ý không làm nằm ở [spec/03-product.md](spec/03-product.md) mục 3.1 và 3.2.

## Cài đặt

Cả hai cách dưới đây chỉ là chỗ giữ chỗ cho đến khi có bản phát hành công khai đầu tiên.

| Cách cài | Lệnh hoặc liên kết |
|---|---|
| DMG đã công chứng (notarized) | Tải tại `https://{{app-slug}}.kal.vn/tai-ve` (chưa có) |
| Homebrew tap | `brew install --cask OWNER/tap/{{app-slug}}` (chủ tài khoản tap: VERIFY) |

Yêu cầu: macOS 15 Sequoia trở lên, máy chip Apple hoặc Intel (bản universal). Những máy chỉ lên được tới macOS 14 chưa được hỗ trợ (PRD-R8; mức tối thiểu này đang chờ người phát triển xác nhận).

Hãy kéo ứng dụng vào thư mục `/Applications` trước lần mở đầu tiên. Ứng dụng sẽ đề nghị tự chuyển vào đó và không xin quyền khi đang chạy từ ổ DMG hoặc một vị trí tạm.

## Quyền riêng tư

- Nội dung bạn gõ không bao giờ rời khỏi máy và không bao giờ được ghi xuống đĩa. Ngoại lệ duy nhất là bản ghi thao tác gõ để báo lỗi do chính bạn bấm bắt đầu: từ 60 đến 180 giây, có đồng hồ đếm ngược hiện rõ, bạn xem lại trước khi chia sẻ, tự xóa sau 24 giờ và không bao giờ tự động gửi đi.
- Lưu lượng mạng tự động duy nhất là kiểm tra cập nhật (appcast và gói cập nhật trên `{{app-slug}}.kal.vn`).
- Không có telemetry, không phân tích sử dụng, không dịch vụ báo cáo sự cố, không cấu hình từ xa.
- Dữ liệu chẩn đoán không chứa ký tự đã gõ, từ đã gõ, nội dung gõ tắt, nội dung bộ nhớ tạm hay tiêu đề cửa sổ.

Chi tiết: [spec/03-product.md](spec/03-product.md) nguyên tắc 4 và mục 11, [spec/02-platform.md](spec/02-platform.md) mục 9. Trang quyền riêng tư công khai là `/rieng-tu` trên website.

## Quyền cần cấp

| Quyền | Để làm gì | Khi nào |
|---|---|---|
| Trợ năng (trên macOS 27 gọi là "Điều khiển thiết bị và truy cập dữ liệu") | Nhận phím gõ, gửi chữ đã sửa, biết ô nào đang được chọn | Luôn cần, xin trong phần hướng dẫn ban đầu |
| Giám sát đầu vào (Input Monitoring) | Chỉ khi macOS không cho tạo bộ bắt phím nếu thiếu quyền này | Chỉ khi cần, và ứng dụng sẽ nói rõ |

Không xin quyền nào khác: không Automation, không Ghi màn hình, không Toàn quyền truy cập đĩa, không Danh bạ, không camera, không truy cập mạng ngoài việc kiểm tra cập nhật. Ô mật khẩu luôn được bỏ qua. Nếu thiếu quyền hoặc quyền bị thu hồi, bàn phím vẫn dùng bình thường và menu chỉ cho bạn cách khắc phục (fail open).

Chi tiết: [spec/02-platform.md](spec/02-platform.md) mục 7. Tên các mục trong Cài đặt hệ thống theo từng phiên bản macOS sẽ được kiểm tra lại trên máy dùng tiếng Việt trước khi phát hành (VERIFY).

## Tự biên dịch

Yêu cầu: macOS với phiên bản Xcode mà dự án cố định (ghi trong workflow CI), [XcodeGen](https://github.com/yonaskolb/XcodeGen), Swift 6.

```sh
# Engine (MPL-2.0, chỉ dùng thư viện chuẩn, cũng build được trên Linux)
cd Packages/VietnameseEngine && swift build && swift test

# Logic của ứng dụng (không có giao diện, không cần cấp quyền)
cd Packages/AppCore && swift build && swift test

# Ứng dụng (.xcodeproj được sinh ra, không commit)
xcodegen generate
xcodebuild -project App.xcodeproj -scheme App -configuration Debug build

# Kiểm tra định dạng và quy tắc
scripts/lint.sh
```

Toàn bộ các lớp kiểm thử, mức độ bao phủ và quy tắc đóng góp nằm trong [CONTRIBUTING.md](CONTRIBUTING.md) (viết bằng tiếng Anh).

## Giấy phép và nguồn gốc mã

- Gói engine dùng giấy phép MPL-2.0: [Packages/VietnameseEngine/LICENSE](Packages/VietnameseEngine/LICENSE).
- Giấy phép của ứng dụng chưa được quyết định. Cho đến khi có quyết định, các tệp nguồn ngoài engine mang dòng `SPDX-License-Identifier: LicenseRef-App-Pending` và chưa có tệp `LICENSE` ở thư mục gốc.
- {{AppName}} là bản cài đặt độc lập, viết theo quy tắc clean-room: [spec/05-clean-room.md](spec/05-clean-room.md). Thành phần bên thứ ba: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Liên kết

- Đặc tả: [spec/README.md](spec/README.md)
- Đóng góp: [CONTRIBUTING.md](CONTRIBUTING.md)
- Báo cáo lỗ hổng bảo mật: [SECURITY.md](SECURITY.md)
- Quy tắc ứng xử: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Nhật ký thay đổi: [CHANGELOG.md](CHANGELOG.md)
- Website: `https://{{app-slug}}.kal.vn`
- Hỗ trợ: GitHub Issues cho lỗi và tương thích, GitHub Discussions cho câu hỏi
