import sys; sys.path.insert(0,'.')
from compose import t, tc
# (keys, im, style, opts, expected_display_before_boundary)
EX = [
# A basic telex
("as","telex","old",{},"á"),("af","telex","old",{},"à"),("ar","telex","old",{},"ả"),("ax","telex","old",{},"ã"),("aj","telex","old",{},"ạ"),
("aa","telex","old",{},"â"),("aw","telex","old",{},"ă"),("ee","telex","old",{},"ê"),("oo","telex","old",{},"ô"),("ow","telex","old",{},"ơ"),
("uw","telex","old",{},"ư"),("dd","telex","old",{},"đ"),("w","telex","old",{},"ư"),("vieetj","telex","old",{},"việt"),("nam","telex","old",{},"nam"),
("tieengs","telex","old",{},"tiếng"),("dduwowcj","telex","old",{},"được"),("nguwowif","telex","old",{},"người"),("khoong","telex","old",{},"không"),("chaof","telex","old",{},"chào"),
("banj","telex","old",{},"bạn"),("cuar","telex","old",{},"của"),("muaf","telex","old",{},"mùa"),("muwaf","telex","old",{},"mừa"),("mias","telex","old",{},"mía"),
("tooi","telex","old",{},"tôi"),("ddaauf","telex","old",{},"đầu"),("nhaf","telex","old",{},"nhà"),("cos","telex","old",{},"có"),("nhuwng","telex","old",{},"nhưng"),("trowif","telex","old",{},"trời"),("nuwowcs","telex","old",{},"nước"),
# B free order
("tieesng","telex","old",{},"tiếng"),("caanf","telex","old",{},"cần"),("caafn","telex","old",{},"cần"),("hopwj","telex","old",{},"hợp"),("howjp","telex","old",{},"hợp"),
("dangd","telex","old",{},"đang"),("chwa","telex","old",{},"chưa"),("hw","telex","old",{},"hư"),("thw","telex","old",{},"thư"),("swr","telex","old",{},"sử"),
("wsng","telex","old",{},"ứng"),("wngs","telex","old",{},"ứng"),("twngf","telex","old",{},"từng"),("ddeens","telex","old",{},"đến"),
("ddeesn","telex","old",{},"đến"),("muoons","telex","old",{},"muốn"),("moojt","telex","old",{},"một"),("mootj","telex","old",{},"một"),("phucws","telex","old",{},"phức"),
("tapj","telex","old",{},"tạp"),("conf","telex","old",{},"còn"),("hangf","telex","old",{},"hàng"),("chinhs","telex","old",{},"chính"),("xacs","telex","old",{},"xác"),
("tawts","telex","old",{},"tắt"),("trawngs","telex","old",{},"trắng"),("hawngf","telex","old",{},"hằng"),("tucj","telex","old",{},"tục"),("nguyeenx","telex","old",{},"nguyễn"),
# C tone placement
("hoaf","telex","old",{},"hòa"),("hoaf","telex","new",{},"hoà"),("khoer","telex","old",{},"khỏe"),("khoer","telex","new",{},"khoẻ"),("thuyr","telex","old",{},"thủy"),
("thuyr","telex","new",{},"thuỷ"),("hoafn","telex","old",{},"hoàn"),("hoafn","telex","new",{},"hoàn"),("toans","telex","old",{},"toán"),("huyts","telex","old",{},"huýt"),
("huynhf","telex","old",{},"huỳnh"),("xoays","telex","old",{},"xoáy"),("hoaif","telex","old",{},"hoài"),("ngoaif","telex","new",{},"ngoài"),
("khuyur","telex","old",{},"khuỷu"),("ngoeoj","telex","old",{},"ngoẹo"),("tuooir","telex","old",{},"tuổi"),("ruwowuj","telex","old",{},"rượu"),("hieeur","telex","old",{},"hiểu"),
("yeeus","telex","old",{},"yếu"),("khuyeenr","telex","old",{},"khuyển"),("thuowr","telex","old",{},"thưở"),("huow","telex","old",{},"hươ"),("mwaf","telex","old",{},"mừa"),
("luwar","telex","old",{},"lửa"),("cuwus","telex","old",{},"cứu"),("guwir","telex","old",{},"gửi"),("soocs","telex","old",{},"sốc"),("sooocs","telex","old",{},"soóc"),
("boooong","telex","old",{},"booong"),("booong","telex","old",{},"boong"),("huychj","telex","old",{},"huỵch"),("tuyps","telex","old",{},"tuýp"),("oaf","telex","old",{},"òa"),
("oaf","telex","new",{},"oà"),("uyr","telex","old",{},"ủy"),("uyr","telex","new",{},"uỷ"),("hoeen","telex","old",{},"hoeen"),("hueej","telex","old",{},"huệ"),
# D gi / qu
("giaf","telex","old",{},"già"),("gif","telex","old",{},"gì"),("gifn","telex","old",{},"gìn"),("gisup","telex","old",{},"giúp"),("giusp","telex","old",{},"giúp"),
("giuwax","telex","old",{},"giữa"),("gieengs","telex","old",{},"giếng"),("gieets","telex","old",{},"giết"),("giuwowngf","telex","old",{},"giường"),("gioir","telex","old",{},"giỏi"),
("quar","telex","old",{},"quả"),("quys","telex","old",{},"quý"),("quis","telex","old",{},"quí"),("quyeets","telex","old",{},"quyết"),("quoocs","telex","old",{},"quốc"),
("quowr","telex","old",{},"quở"),("quawng","telex","old",{},"quăng"),("quaanf","telex","old",{},"quần"),("quyfnh","telex","old",{},"quỳnh"),("quaay","telex","old",{},"quây"),
# E uo horn
("tuowng","telex","old",{},"tương"),("tuwowng","telex","old",{},"tương"),("tuwong","telex","old",{},"tương"),("thuowng","telex","old",{},"thương"),("cuwowis","telex","old",{},"cưới"),
("cuwowiso","telex","old",{},"cuối"),("cuoois","telex","old",{},"cuối"),("cuooisw","telex","old",{},"cưới"),("huouw","telex","old",{},"hươu"),("thuoww","telex","old",{},"thuow"),
# F escape / doubling
("ass","telex","old",{},"as"),("aaa","telex","old",{},"aa"),("aww","telex","old",{},"aw"),("ddd","telex","old",{},"dd"),("ddi","telex","old",{},"đi"),
("ddid","telex","old",{},"did"),("ww","telex","old",{},"w"),("www","telex","old",{},"ww"),("uww","telex","old",{},"uw"),("nhaamff","telex","old",{},"nhâmf"),
("nhes","telex","old",{},"nhé"),("nhese","telex","old",{},"nhế"),("nhesee","telex","old",{},"nhée"),("chuwaa","telex","old",{},"chưaa"),("cuaa","telex","old",{},"cuaa"),
("khoaa","telex","old",{},"khoaa"),("boss","telex","old",{},"bos"),("traffic","telex","old",{},"trafic"),("wfa","telex","old",{},"ừa"),("wfaaa","telex","old",{},"ừaaa"),
# G tone removal
("asz","telex","old",{},"a"),("aszz","telex","old",{},"az"),("quz","telex","old",{},"quz"),("QUZ","telex","old",{},"QUZ"),("qutz","telex","old",{},"qutz"),
("za","telex","old",{},"za"),("zas","telex","old",{},"zá"),("vieejtz","telex","old",{},"viêt"),
# H VNI
("a1","vni","old",{},"á"),("a2","vni","old",{},"à"),("a3","vni","old",{},"ả"),("a4","vni","old",{},"ã"),("a5","vni","old",{},"ạ"),
("a6","vni","old",{},"â"),("a8","vni","old",{},"ă"),("o7","vni","old",{},"ơ"),("u7","vni","old",{},"ư"),("d9","vni","old",{},"đ"),
("vie65t","vni","old",{},"việt"),("vie6t5","vni","old",{},"việt"),("tieng61","vni","old",{},"tiếng"),("nhieu62","vni","old",{},"nhiều"),("nua73","vni","old",{},"nửa"),
("duoc795","vni","old",{},"được"),("d9uo7c5","vni","old",{},"được"),("truong72","vni","old",{},"trường"),("mot65","vni","old",{},"một"),("hoa2","vni","old",{},"hòa"),
("hoa2","vni","new",{},"hoà"),("a11","vni","old",{},"a1"),("a66","vni","old",{},"a6"),("d99","vni","old",{},"d9"),("qu0","vni","old",{},"qu0"),
("a10","vni","old",{},"a"),("2024","vni","old",{},"2024"),("b2","vni","old",{},"b2"),("u7a4","vni","old",{},"ữa"),("gio61ng","vni","old",{},"giống"),
("quy1","vni","old",{},"quý"),("ca6u2","vni","old",{},"cầu"),("kho6ng","vni","old",{},"không"),("huo7","vni","old",{},"hươ"),("Kro6ng","vni","old",{},"Krông"),("gi1up","vni","old",{},"giúp"),("ho2an","vni","old",{},"hoàn"),("ho2a","vni","old",{},"hòa"),("ho2a","vni","new",{},"hoà"),("tie61ng","vni","old",{},"tiếng"),("ddu7o7c5","vni","old",{},"ddu7o7c5"),("vieejt","vni","old",{},"vieejt"),
# I case
("Vieetj","telex","old",{},"Việt"),("VIEETJ","telex","old",{},"VIỆT"),("DDaf","telex","old",{},"Đà"),("Ddaf","telex","old",{},"Đà"),("dDaf","telex","old",{},"đà"),
("TIEENGS","telex","old",{},"TIẾNG"),("TieengS","telex","old",{},"Tiếng"),("W","telex","old",{},"Ư"),("NGUWOWIF","telex","old",{},"NGƯỜI"),("Aas","telex","old",{},"Ấ"),
# J non-viable / english while typing
("text","telex","old",{},"tẽt"),("user","telex","old",{},"ủe"),("wifi","telex","old",{},"ừii"),("USB","telex","old",{},"ÚB"),("case","telex","old",{},"cáe"),
("mother","telex","old",{},"mother"),("keyboard","telex","old",{},"keyboard"),("startup","telex","old",{},"startup"),("facebook","telex","old",{},"facebook"),("java","telex","old",{},"java"),
("password","telex","old",{},"pasword"),("verbose","telex","old",{},"vẻbose"),("qw","telex","old",{},"qw"),("qww","telex","old",{},"qww"),("year","telex","old",{},"year"),
# K names / loans
("Kroong","telex","old",{},"Krông"),("DDawsk","telex","old",{},"Đắk"),("Lawsk","telex","old",{},"Lắk"),("Pawsc","telex","old",{},"Pắc"),("Thuootj","telex","old",{},"Thuột"),
("Buoon","telex","old",{},"Buôn"),("pias","telex","old",{},"pía"),("buyts","telex","old",{},"buýt"),("quowrn","telex","old",{},"quởn"),("huow","telex","old",{},"hươ"),
# L backspace
("vieejt⌫","telex","old",{},"việ"),("vieejt⌫⌫","telex","old",{},"vi"),("hoaf⌫","telex","old",{},"hò"),("hoaf⌫","telex","new",{},"ho"),("hoafn⌫","telex","old",{},"hòa"),
("nhaamff⌫","telex","old",{},"nhầm"),("ass⌫","telex","old",{},"á"),("duwowngf⌫⌫⌫","telex","old",{},"dư"),
# N options
("[","telex","old",{"brackets":True},"ơ"),("]","telex","old",{"brackets":True},"ư"),("w","telex","old",{"standalone_w":False},"w"),("tw","telex","old",{"standalone_w":False},"tw"),("tuw","telex","old",{"standalone_w":False},"tư"),
]
bad=0
for keys,im,style,opts,exp in EX:
    got=t(keys,im,style,**opts)
    if got!=exp:
        bad+=1; print('MISMATCH',keys,im,style,opts,'exp',exp,'got',got)
print('total',len(EX),'mismatch',bad)
import json
json.dump([[k,im,st,o,exp] for k,im,st,o,exp in EX],open('examples.json','w'),ensure_ascii=False)
