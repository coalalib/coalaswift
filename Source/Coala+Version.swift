//
//  Coala+Version.swift
//  Coala
//
//  Created by Roman on 04/12/2017.
//  Copyright © 2017 NDM Systems. All rights reserved.
//

extension Coala {
    public static var frameworkVersion: String {
        guard let infoDictionary = Bundle(identifier: "com.ndmsystems.Coala")?.infoDictionary,
            let shortVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
                return ""
        }
        return "\(shortVersion)-\(Int(CoalaVersionNumber))"
    }
}
