
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "categories": {
                  Row: {
                    "default_rank": number,"id": number,"name": string,"slug": string
                  }
                  ComputedFields: never
                  Insert: {
                    "default_rank": number,"id"?: never,"name": string,"slug": string
                  }
                  Update: {
                    "default_rank"?: number,"id"?: never,"name"?: string,"slug"?: string
                  }
                  Relationships: [
                    
                  ]
                },"checks": {
                  Row: {
                    "category_id": number | null,"checked_at": string,"id": string,"ignored": boolean,"product_id": string | null,"visit_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "category_id"?: number | null,"checked_at": string,"id": string,"ignored"?: boolean,"product_id"?: string | null,"visit_id": string
                  }
                  Update: {
                    "category_id"?: number | null,"checked_at"?: string,"id"?: string,"ignored"?: boolean,"product_id"?: string | null,"visit_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "checks_category_id_fkey"
      columns: ["category_id"]
isOneToOne: false
      referencedRelation: "categories"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "checks_product_id_fkey"
      columns: ["product_id"]
isOneToOne: false
      referencedRelation: "products"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "checks_visit_id_fkey"
      columns: ["visit_id"]
isOneToOne: false
      referencedRelation: "visits"
      referencedColumns: ["id"]
    }
                  ]
                },"list_item_tombstones": {
                  Row: {
                    "deleted_at": string,"id": string,"list_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "deleted_at"?: string,"id": string,"list_id": string
                  }
                  Update: {
                    "deleted_at"?: string,"id"?: string,"list_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "list_item_tombstones_list_id_fkey"
      columns: ["list_id"]
isOneToOne: false
      referencedRelation: "lists"
      referencedColumns: ["id"]
    }
                  ]
                },"list_items": {
                  Row: {
                    "checked_at": string | null,"created_at": string,"id": string,"label": string,"list_id": string,"product_id": string | null,"quantity": string | null,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "checked_at"?: string | null,"created_at"?: string,"id"?: string,"label": string,"list_id": string,"product_id"?: string | null,"quantity"?: string | null,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "checked_at"?: string | null,"created_at"?: string,"id"?: string,"label"?: string,"list_id"?: string,"product_id"?: string | null,"quantity"?: string | null,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "list_items_list_id_fkey"
      columns: ["list_id"]
isOneToOne: false
      referencedRelation: "lists"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "list_items_product_id_fkey"
      columns: ["product_id"]
isOneToOne: false
      referencedRelation: "products"
      referencedColumns: ["id"]
    }
                  ]
                },"list_members": {
                  Row: {
                    "added_by": string | null,"created_at": string,"list_id": string,"role": string,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "added_by"?: string | null,"created_at"?: string,"list_id": string,"role": string,"updated_at"?: string,"user_id": string
                  }
                  Update: {
                    "added_by"?: string | null,"created_at"?: string,"list_id"?: string,"role"?: string,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "list_members_list_id_fkey"
      columns: ["list_id"]
isOneToOne: false
      referencedRelation: "lists"
      referencedColumns: ["id"]
    }
                  ]
                },"lists": {
                  Row: {
                    "created_at": string,"id": string,"name": string,"owner_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"name"?: string,"owner_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"name"?: string,"owner_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"products": {
                  Row: {
                    "category_id": number | null,"created_at": string,"id": string,"name": string,"normalized_name": string,"off_code": string | null,"published_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "category_id"?: number | null,"created_at"?: string,"id"?: string,"name": string,"normalized_name": string,"off_code"?: string | null,"published_at"?: string | null
                  }
                  Update: {
                    "category_id"?: number | null,"created_at"?: string,"id"?: string,"name"?: string,"normalized_name"?: string,"off_code"?: string | null,"published_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "products_category_id_fkey"
      columns: ["category_id"]
isOneToOne: false
      referencedRelation: "categories"
      referencedColumns: ["id"]
    }
                  ]
                },"profiles": {
                  Row: {
                    "created_at": string,"display_name": string,"updated_at": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"display_name": string,"updated_at"?: string,"user_id"?: string
                  }
                  Update: {
                    "created_at"?: string,"display_name"?: string,"updated_at"?: string,"user_id"?: string
                  }
                  Relationships: [
                    
                  ]
                },"store_edges": {
                  Row: {
                    "last_seen_at": string,"observations": number,"product_a": string,"product_b": string,"store_id": string,"weight": number
                  }
                  ComputedFields: never
                  Insert: {
                    "last_seen_at": string,"observations"?: number,"product_a": string,"product_b": string,"store_id": string,"weight"?: number
                  }
                  Update: {
                    "last_seen_at"?: string,"observations"?: number,"product_a"?: string,"product_b"?: string,"store_id"?: string,"weight"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "store_edges_product_a_fkey"
      columns: ["product_a"]
isOneToOne: false
      referencedRelation: "products"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "store_edges_product_b_fkey"
      columns: ["product_b"]
isOneToOne: false
      referencedRelation: "products"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "store_edges_store_id_fkey"
      columns: ["store_id"]
isOneToOne: false
      referencedRelation: "stores"
      referencedColumns: ["id"]
    }
                  ]
                },"store_entries": {
                  Row: {
                    "last_seen_at": string,"observations": number,"product_id": string,"store_id": string,"weight": number
                  }
                  ComputedFields: never
                  Insert: {
                    "last_seen_at": string,"observations"?: number,"product_id": string,"store_id": string,"weight"?: number
                  }
                  Update: {
                    "last_seen_at"?: string,"observations"?: number,"product_id"?: string,"store_id"?: string,"weight"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "store_entries_product_id_fkey"
      columns: ["product_id"]
isOneToOne: false
      referencedRelation: "products"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "store_entries_store_id_fkey"
      columns: ["store_id"]
isOneToOne: false
      referencedRelation: "stores"
      referencedColumns: ["id"]
    }
                  ]
                },"store_graph_snapshots": {
                  Row: {
                    "algo_version": number,"checked_at": string,"etag": string,"generated_at": string,"payload": NonNullable<Json>,"payload_bytes": number,"snapshot_version": number,"store_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "algo_version": number,"checked_at": string,"etag": string,"generated_at": string,"payload": NonNullable<Json>,"payload_bytes": number,"snapshot_version": number,"store_id": string
                  }
                  Update: {
                    "algo_version"?: number,"checked_at"?: string,"etag"?: string,"generated_at"?: string,"payload"?: NonNullable<Json>,"payload_bytes"?: number,"snapshot_version"?: number,"store_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "store_graph_snapshots_store_id_fkey"
      columns: ["store_id"]
isOneToOne: true
      referencedRelation: "stores"
      referencedColumns: ["id"]
    }
                  ]
                },"store_stats": {
                  Row: {
                    "confidence": number,"confidence_q": number,"graph_changed_at": string | null,"last_visit_at": string | null,"store_id": string,"updated_at": string,"v_eff": number,"v_eff_at": string | null,"visits_count": number
                  }
                  ComputedFields: never
                  Insert: {
                    "confidence"?: number,"confidence_q"?: number,"graph_changed_at"?: string | null,"last_visit_at"?: string | null,"store_id": string,"updated_at"?: string,"v_eff"?: number,"v_eff_at"?: string | null,"visits_count"?: number
                  }
                  Update: {
                    "confidence"?: number,"confidence_q"?: number,"graph_changed_at"?: string | null,"last_visit_at"?: string | null,"store_id"?: string,"updated_at"?: string,"v_eff"?: number,"v_eff_at"?: string | null,"visits_count"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "store_stats_store_id_fkey"
      columns: ["store_id"]
isOneToOne: true
      referencedRelation: "stores"
      referencedColumns: ["id"]
    }
                  ]
                },"stores": {
                  Row: {
                    "address": string | null,"chain": string | null,"created_at": string,"id": string,"location": unknown,"name": string,"organic_aisle": boolean,"osm_id": number | null,"osm_seen_at": string | null,"osm_type": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "address"?: string | null,"chain"?: string | null,"created_at"?: string,"id"?: string,"location": unknown,"name": string,"organic_aisle"?: boolean,"osm_id"?: number | null,"osm_seen_at"?: string | null,"osm_type"?: string | null
                  }
                  Update: {
                    "address"?: string | null,"chain"?: string | null,"created_at"?: string,"id"?: string,"location"?: unknown,"name"?: string,"organic_aisle"?: boolean,"osm_id"?: number | null,"osm_seen_at"?: string | null,"osm_type"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"visits": {
                  Row: {
                    "auto_closed": boolean,"ended_at": string | null,"id": string,"learn_outcome": string | null,"learn_weight": number | null,"list_id": string | null,"list_was_sorted": boolean,"next_attempt_at": string | null,"process_attempts": number,"process_error": string | null,"processed_algo_version": number | null,"processed_at": string | null,"started_at": string,"store_id": string,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "auto_closed"?: boolean,"ended_at"?: string | null,"id"?: string,"learn_outcome"?: string | null,"learn_weight"?: number | null,"list_id"?: string | null,"list_was_sorted": boolean,"next_attempt_at"?: string | null,"process_attempts"?: number,"process_error"?: string | null,"processed_algo_version"?: number | null,"processed_at"?: string | null,"started_at"?: string,"store_id": string,"user_id"?: string
                  }
                  Update: {
                    "auto_closed"?: boolean,"ended_at"?: string | null,"id"?: string,"learn_outcome"?: string | null,"learn_weight"?: number | null,"list_id"?: string | null,"list_was_sorted"?: boolean,"next_attempt_at"?: string | null,"process_attempts"?: number,"process_error"?: string | null,"processed_algo_version"?: number | null,"processed_at"?: string | null,"started_at"?: string,"store_id"?: string,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "visits_list_id_fkey"
      columns: ["list_id"]
isOneToOne: false
      referencedRelation: "lists"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "visits_store_id_fkey"
      columns: ["store_id"]
isOneToOne: false
      referencedRelation: "stores"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "accept_invitation":
{ Args: { "p_invitation_id"?: string,"p_token"?: string }; Returns: {
              "list_id": string,"role": string,"status": string
            }[]
                           },
"accessible_list_ids":
{ Args: Record<PropertyKey, never>; Returns: {
              "id": string
            }[]
                           },
"attestation_challenge":
{ Args: Record<PropertyKey, never>; Returns: string
                           },
"claim_inactivity_notices":
{ Args: { "p_limit"?: number }; Returns: {
              "cycle_id": string,"email": string,"purge_after": string,"user_id": string
            }[]
                           },
"confirm_inactivity_notice":
{ Args: { "p_cycle_id": string,"p_user_id": string }; Returns: boolean
                           },
"consume_attestation_challenge":
{ Args: { "p_challenge": string,"p_user_id": string }; Returns: boolean
                           },
"create_invitation":
{ Args: { "p_email": string,"p_list_id": string,"p_role"?: string,"p_send_email"?: boolean }; Returns: {
              "expires_at": string,"invitation_id": string,"invitee_email": string,"sender_name": string,"token": string
            }[]
                           },
"decline_invitation":
{ Args: { "p_invitation_id": string }; Returns: undefined
                           },
"delete_my_account":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"list_sharing":
{ Args: { "p_list_id": string }; Returns: Json
                           },
"my_invitations":
{ Args: Record<PropertyKey, never>; Returns: {
              "expires_at": string,"id": string,"inviter_name": string,"list_id": string,"list_name": string,"role": string
            }[]
                           },
"nearby_stores":
{ Args: { "lat": number,"lng": number,"max_results"?: number,"radius_m"?: number }; Returns: {
              "address": string,"chain": string,"distance_m": number,"id": string,"name": string,"organic_aisle": boolean
            }[]
                           },
"normalize_label":
{ Args: { "label": string }; Returns: string
                           },
"preview_invitation":
{ Args: { "p_token": string }; Returns: {
              "email_matches": boolean,"expires_at": string,"invitation_id": string,"invited_email_masked": string,"inviter_name": string,"list_id": string,"list_name": string,"role": string,"status": string
            }[]
                           },
"record_device_attestation":
{ Args: { "p_platform": string,"p_user_id": string }; Returns: undefined
                           },
"remove_member":
{ Args: { "p_list_id": string,"p_user_id": string }; Returns: undefined
                           },
"resolve_products":
{ Args: { "p_items": Json }; Returns: {
              "category_slug": string,"id": string,"name": string,"normalized_name": string
            }[]
                           },
"revoke_invitation":
{ Args: { "p_invitation_id": string }; Returns: undefined
                           },
"search_stores":
{ Args: { "max_results"?: number,"q": string }; Returns: {
              "address": string,"chain": string,"id": string,"name": string,"organic_aisle": boolean
            }[]
                           },
"set_member_role":
{ Args: { "p_list_id": string,"p_role": string,"p_user_id": string }; Returns: undefined
                           },
"store_graph_snapshot":
{ Args: { "p_known_version"?: number,"p_store_id": string }; Returns: Json
                           },
"unpublished_products":
{ Args: { "p_since"?: string }; Returns: {
              "id": string,"unpublished_at": string
            }[]
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            
          }
        }
} as const
