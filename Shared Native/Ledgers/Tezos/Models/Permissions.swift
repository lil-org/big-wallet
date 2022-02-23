// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

// Идея:
//  После того как открыли коннект для работы с сообщениями
//  к нам приходят либо запросы на дейсвие(SignPayload, Operation), либо на бродкаст(BroadcastRequest), либо на Threshold(это сколько можно автоматически переводить денег, без дальнейшего запроса).
//
// ping, pong,

//export interface BaseMessage {
//  type: MessageType;
//  version: string;
//  id: string; // ID of the message. The same ID is used in the request and response
//  senderId: string; // ID of the sender. This is used to identify the sender of the message
//}

//export enum PermissionScope {
//  SIGN = "sign",
//  OPERATION_REQUEST = "operation_request",
//  THRESHOLD = "threshold",
//}
//
//export interface PermissionRequest extends BaseMessage {
//  version: string;
//  id: string;
//  senderId: string;
//  type: MessageType.PermissionRequest;
//  appMetadata: AppMetadata;
//  network: Network;
//  scopes: PermissionScope[];
//}

// 
