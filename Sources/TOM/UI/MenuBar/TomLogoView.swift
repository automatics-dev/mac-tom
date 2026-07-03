import SwiftUI

struct TomLogoView: View {
    var color: Color = .white

    var body: some View {
        if let url = Bundle.main.url(forResource: "tomlogo", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(color)
        } else {
            Text("tom")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .italic()
                .foregroundColor(color)
        }
    }
}
