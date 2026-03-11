//
//  Item.swift
//  omni-asr
//
//  Created by Christopher Witzl on 11.03.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
