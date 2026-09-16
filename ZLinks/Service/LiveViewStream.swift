//
//  LiveViewStream.swift
//  ZLinks
//
//  实时图传画面单独发布。
//
//  拉流时每秒会产生几十帧画面，如果直接放到 CameraConnectionService 的
//  @Published 属性上，每一帧都会让「我的相机 / 图库 / 拍摄」整个层级重建，
//  掉帧几乎全部来自这里。把画面放进独立的 ObservableObject 后，只有真正
//  渲染画面的监看视图会随帧刷新。
//

import Combine
import UIKit

@MainActor
final class LiveViewStream: ObservableObject {
    @Published private(set) var image: UIImage?

    func setImage(_ image: UIImage?) {
        self.image = image
    }

    func reset() {
        if image != nil {
            image = nil
        }
    }
}
