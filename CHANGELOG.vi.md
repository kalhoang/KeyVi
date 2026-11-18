# Nhật ký thay đổi

Mọi thay đổi đáng chú ý của KeyVi được ghi trong file này. Phiên bản 1.0.0 là bản phát hành công khai đầu tiên; các bản thử nghiệm riêng trước đó không được liệt kê.

Đây là bản tiếng Việt của [CHANGELOG.md](CHANGELOG.md), có cùng các tiêu đề phiên bản, và là nguồn của trang nhật ký thay đổi tiếng Việt trên website. Định dạng theo [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); số phiên bản theo [Semantic Versioning](https://semver.org/) (QA-R26).

Mỗi phiên bản ghi đầy đủ các thay đổi ở đây. Cửa sổ cập nhật chỉ hiện ghi chú phát hành ngắn, tối đa năm dòng cho mỗi ngôn ngữ (mục danh sách và đoạn văn; tiêu đề nhóm không tính, PRD-R51). Phần nào có từ năm dòng trở xuống thì được dùng luôn làm ghi chú phát hành, như bản 1.0.0; phần dài hơn thì ghi chú phát hành là một file ngắn tóm tắt lại, truyền bằng `--notes-vi`, và cửa sổ cập nhật có liên kết tới phần đầy đủ ở đây. Nội dung viết bằng lời người dùng hiểu được và nêu tên ứng dụng liên quan (QA-R66, QA-R67). Các nhóm dùng tiêu đề tiếng Việt: Thêm, Thay đổi, Sắp bỏ, Đã bỏ, Sửa lỗi, Bảo mật và Lỗi đã biết (ứng với Added, Changed, Deprecated, Removed, Fixed, Security và Known issues của bản tiếng Anh).

## [Unreleased]

### Sửa lỗi

- Từ đầu tiên bạn gõ ngay sau khi một ứng dụng tự chuyển sang ô nhập khác không còn bị mất dấu hay sai dấu ("tieengs" thay vì "tiếng").
- Từ đầu tiên bạn gõ ngay khi một ứng dụng mở khung tìm kiếm riêng không còn bị mất dấu ("vieejt" thay vì "việt") khi ô tìm kiếm của khung đó sẵn sàng chậm hơn phím đầu tiên một chút.
- KeyVi nay tiếp tục theo dõi một ứng dụng đã từ chối thông báo chuyển ô nhập trong vài giây đầu sau khi mở, nên các lần chuyển ô trong ứng dụng đó không còn bị bỏ sót cho tới khi bạn chuyển sang ứng dụng khác.

## [1.0.1-beta.1] - 2026-11-18

### Thay đổi

- Khi phím cuối cùng của một từ là phím xóa dấu (z trong Telex, 0 trong VNI), chữ không dấu bạn đang thấy được giữ nguyên khi kết thúc từ, ví dụ "duong", thay vì trở lại các phím đã gõ.
- Các cụm tiếng Anh "day off", "sale off" và "a mess" nay giữ đúng từ bạn gõ, không còn bị đổi thành "day of", "sale of" và "a mes".

### Sửa lỗi

- Trong Terminal, iTerm2 và các trình soạn mã, các lệnh như chown, awk và ps -ef nay giữ nguyên như bạn gõ, không còn bị đổi thành chữ tiếng Việt (chơn, ăk, è); trong câu tiếng Việt, chúng vẫn được gõ thành tiếng Việt.

## [1.0.0] - 2026-11-18

- Bản phát hành công khai đầu tiên của KeyVi: gõ tiếng Việt (Telex hoặc VNI) và tiếng Anh trong cùng một câu mà không cần chuyển chế độ. Từ tiếng Anh như "file" hay "server" giữ đúng như bạn gõ, dù từ kết thúc bằng phím nào, còn những từ có thể là cả hai, như as hay á, được chọn theo các từ xung quanh.
- Nhấn Escape ngay sau một từ để lấy lại đúng các phím bạn đã gõ; nhấn thêm lần nữa thì Escape hoạt động như bình thường. KeyVi không dùng Escape trong cửa sổ dòng lệnh, trình soạn mã, trò chơi, ứng dụng điều khiển máy tính từ xa và các trình khởi chạy như Spotlight, Raycast và Alfred.
- KeyVi học từ những lần bạn sửa từ trong từng ứng dụng: một từ bạn sửa giống nhau hai lần trong một ứng dụng sẽ được gõ như vậy trong ứng dụng đó từ lần sau. Cài đặt > Kiểu gõ liệt kê các từ đã học kèm tên ứng dụng để bạn xem lại, cho một từ áp dụng trong mọi ứng dụng hoặc xóa từ đó.
- Mỗi ứng dụng nhớ chế độ tiếng Việt hay tiếng Anh riêng và có thể có quy tắc riêng. Viết tắt giúp bạn gõ nhanh những đoạn chữ dài, và hai danh sách từ "Giữ nguyên như đã gõ" và "Giữ là tiếng Việt" quyết định cách những từ bạn thêm vào đó hiện ra.
- Có sẵn cài đặt cho các ứng dụng thông dụng, trong đó có Safari, Google Chrome, Slack, Zalo, Microsoft Office, Spotlight, Terminal, iTerm2 và Visual Studio Code. Những gì bạn gõ không bao giờ rời khỏi máy Mac: kết nối mạng tự động duy nhất là kiểm tra cập nhật.
