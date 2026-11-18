# KeyVi™

[English](README.md)

KeyVi™ là bộ gõ tiếng Việt cho macOS do Kal tự viết từ đầu. Đây là ứng dụng nằm trên thanh menu, gõ tiếng Việt (Telex hoặc VNI) trong mọi ứng dụng, tự khôi phục từ tiếng Anh, và nói rõ cho bạn biết khi có điều gì đó không hoạt động được.

> **Về tên:** tên sản phẩm và các định danh đi kèm (slug, bundle ID, địa chỉ website) lấy từ [`Config/Brand.xcconfig`](Config/Brand.xcconfig) và [`scripts/brand.env`](scripts/brand.env).

## Tình trạng

**Phiên bản 1.0, bản phát hành công khai đầu tiên (18/11/2026).** Bạn tải ứng dụng tại website: [keyvi.kal.vn/tai-ve](https://keyvi.kal.vn/tai-ve/). Các bản đã cài tự cập nhật qua Sparkle.

Mọi bản phát hành đều phải đạt các bài kiểm thử P0 (PRD-R0). Ba mục P0 là lý do dự án này tồn tại:

1. Gõ không bao giờ bị chặn "ngẫu nhiên": ứng dụng chỉ tạm dừng khi hệ điều hành báo chế độ nhập bảo mật hoặc khi ô đang gõ thật sự là ô mật khẩu, và cho bạn biết ứng dụng nào đang giữ chế độ đó.
2. Gõ được tiếng lóng như `dzô` và `hẹo`: tính hợp lệ dựa trên quy tắc chính tả tiếng Việt, không dựa vào từ điển.
3. Tự quay về tiếng Anh hoạt động với mọi phím kết thúc từ (dấu câu, Return, Tab), không chỉ phím Space.

Cách bản 1.0 được phát hành mà không qua beta công khai, cùng những tiêu chí của lộ trình đã đạt hoặc được miễn, được ghi trong [ADR 0507](docs/decisions/0507-first-public-release-1-0.md). Lộ trình cùng tiêu chí vào và ra của từng giai đoạn nằm ở [spec/03-product.md](spec/03-product.md) mục 3.3; những thay đổi của từng bản nằm ở [CHANGELOG.vi.md](CHANGELOG.vi.md). README này không nêu điều gì vượt ra ngoài bản đặc tả.

## Đây là gì

- Gõ Telex và VNI, kết quả theo Unicode (NFC).
- Tự khôi phục từ tiếng Anh bằng dữ liệu đi kèm, không cần tải thêm.
- Nhớ chế độ Việt/Anh theo từng ứng dụng và quy tắc riêng cho từng ứng dụng.
- Viết tắt (macro).
- Biểu tượng trạng thái trên thanh menu, hướng dẫn ban đầu có ô gõ thử, cửa sổ Cài đặt gọn.
- Chẩn đoán và báo lỗi một chạm, không bao giờ chứa nội dung bạn đã gõ.
- Cập nhật qua Sparkle 2, có kênh ổn định và kênh beta.
- Giao diện tiếng Việt và tiếng Anh.

Phạm vi đầy đủ và danh sách những thứ cố ý không làm nằm ở [spec/03-product.md](spec/03-product.md) mục 3.1 và 3.2.

## Cài đặt

| Cách cài | Lệnh hoặc liên kết |
|---|---|
| DMG đã công chứng (notarized) | Tải tại [keyvi.kal.vn/tai-ve](https://keyvi.kal.vn/tai-ve/) |
| Homebrew tap | `brew install --cask kalhoang/tap/keyvi` |

Yêu cầu: macOS 12 Monterey trở lên, máy chip Apple hoặc Intel (bản universal) (PRD-R8, [ADR 0315](docs/decisions/0315-minimum-macos-12.md)).

Hãy kéo ứng dụng vào thư mục `/Applications` trước lần mở đầu tiên. Ứng dụng sẽ đề nghị tự chuyển vào đó và không xin quyền khi đang chạy từ ổ DMG hoặc một vị trí tạm.

## Quyền riêng tư

- Nội dung bạn gõ không bao giờ rời khỏi máy và không bao giờ được ghi xuống đĩa. Ngoại lệ duy nhất là bản ghi thao tác gõ để báo lỗi do chính bạn bấm bắt đầu: từ 60 đến 180 giây, có đồng hồ đếm ngược hiện rõ, bạn xem lại trước khi chia sẻ, tự xóa sau 24 giờ và không bao giờ tự động gửi đi.
- Lưu lượng mạng tự động duy nhất là kiểm tra cập nhật (appcast và gói cập nhật trên `keyvi.kal.vn`).
- Không có telemetry, không phân tích sử dụng, không dịch vụ báo cáo sự cố, không cấu hình từ xa.
- Dữ liệu chẩn đoán không chứa ký tự đã gõ, từ đã gõ, nội dung viết tắt, nội dung bộ nhớ tạm hay tiêu đề cửa sổ.

Chi tiết: [spec/03-product.md](spec/03-product.md) nguyên tắc 4 và mục 11, [spec/02-platform.md](spec/02-platform.md) mục 9. Trang quyền riêng tư công khai là `/rieng-tu` trên website.

## Quyền cần cấp

| Quyền | Để làm gì | Khi nào |
|---|---|---|
| Trợ năng (trên macOS 27 gọi là "Điều khiển thiết bị và truy cập dữ liệu") | Nhận phím gõ, gửi chữ đã sửa, biết ô nào đang được chọn | Luôn cần, xin trong phần hướng dẫn ban đầu |
| Giám sát đầu vào (Input Monitoring) | Chỉ khi macOS không cho tạo bộ bắt phím nếu thiếu quyền này | Chỉ khi cần, và ứng dụng sẽ nói rõ |

Không xin quyền nào khác: không Automation, không Ghi màn hình, không Toàn quyền truy cập đĩa, không Danh bạ, không camera, không truy cập mạng ngoài việc kiểm tra cập nhật. Ô mật khẩu luôn được bỏ qua. Nếu thiếu quyền hoặc quyền bị thu hồi, bàn phím vẫn dùng bình thường và menu chỉ cho bạn cách khắc phục (fail open).

Chi tiết: [spec/02-platform.md](spec/02-platform.md) mục 7. Quản trị viên CNTT muốn cấp sẵn các quyền này bằng hồ sơ quản lý thiết bị (MDM): xem [Managed Macs](docs/support/managed-macs.md) (tiếng Anh). Tên các mục trong Cài đặt hệ thống theo từng phiên bản macOS sẽ được kiểm tra lại trên máy dùng tiếng Việt trước khi phát hành (VERIFY).

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

- KeyVi™ là phần mềm tự do theo Giấy phép Công cộng GNU (GNU GPL), phiên bản 3 hoặc (tùy bạn chọn) bất kỳ phiên bản nào mới hơn: [LICENSE](LICENSE). Bản quyền (c) 2026 thuộc các tác giả của KeyVi.
- Các gói engine tiếng Việt, quy trình tạo danh sách từ và mô hình tham chiếu dùng Giấy phép Công cộng Mozilla 2.0 (MPL-2.0): mọi ứng dụng, mã nguồn mở hay không, đều có thể nhúng vào, còn thay đổi trên chính các file này vẫn phải công khai: [Packages/VietnameseEngine/LICENSE](Packages/VietnameseEngine/LICENSE), [Packages/VietnameseEngineFuzz/LICENSE](Packages/VietnameseEngineFuzz/LICENSE), [data/LICENSE](data/LICENSE), [spec/reference-model/LICENSE](spec/reference-model/LICENSE). Dòng bản quyền nằm trong các file `NOTICE` đi kèm.
- Mọi đóng góp cần dòng ký xác nhận (Developer Certificate of Origin); mọi đóng góp đồng thời được cấp cho dự án theo giấy phép MIT, không cần ký CLA ([CONTRIBUTING.md](CONTRIBUTING.md) mục 3, [ADR 0006](docs/decisions/0006-app-licence-and-pro-edition.md)).
- KeyVi™ là bản cài đặt độc lập, viết theo quy tắc clean-room: [spec/05-clean-room.md](spec/05-clean-room.md). Thành phần bên thứ ba: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Liên kết

- Đặc tả: [spec/README.md](spec/README.md)
- Đóng góp: [CONTRIBUTING.md](CONTRIBUTING.md)
- Báo cáo lỗ hổng bảo mật: [SECURITY.md](SECURITY.md)
- Quy tắc ứng xử: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Nhật ký thay đổi: [CHANGELOG.vi.md](CHANGELOG.vi.md) (tiếng Anh: [CHANGELOG.md](CHANGELOG.md))
- Website: `https://keyvi.kal.vn`
- Hỗ trợ: GitHub Issues cho lỗi và tương thích, GitHub Discussions cho câu hỏi
