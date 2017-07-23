--  part of AdaYaml, (c) 2017 Felix Krause
--  released under the terms of the MIT license, see the file "copying.txt"

with Ada.Containers;

package body Yaml.Parser is
   use type Lexer.Token_Kind;
   use type Text.Reference;

   procedure Init (P : not null access Implementation) with Inline is
   begin
      P.Levels.Push ((State => At_Stream_Start'Access, Indentation => -2));
      Tag_Handle_Sets.Init (P.Tag_Handles, P.Pool, 16);
   end Init;

   procedure Set_Input (P : in out Reference; Input : Source.Pointer) is
      Pool : Text.Pool.Reference;
   begin
      Pool.Create (8092);
      declare
         PI : constant not null access Implementation :=
           new Implementation'(Stream.Implementation with
              L => <>, Pool => Pool, Levels => Level_Stacks.New_Stack (32),
              Current => <>, Cached => <>, Header_Props => <>,
              Inline_Props => <>, Header_Start => <>, Inline_Start => <>,
              Tag_Handles => <>, Block_Indentation => <>);
      begin
         Lexer.Init (PI.L, Input, Pool);
         Init (PI);
         Stream.Create (P, Stream.Implementation_Pointer (PI));
      end;
   end Set_Input;

   procedure Set_Input (P : in out Reference; Input : String) is
      Pool : Text.Pool.Reference;
   begin
      Pool.Create (8092);
      declare
         PI : constant not null access Implementation :=
           new Implementation'(Stream.Implementation with
              L => <>, Pool => Pool, Levels => Level_Stacks.New_Stack (32),
              Current => <>, Cached => <>, Header_Props => <>,
              Inline_Props => <>, Header_Start => <>, Inline_Start => <>,
              Tag_Handles => <>, Block_Indentation => <>);
      begin
         Lexer.Init (PI.L, Input, Pool);
         Init (PI);
         Stream.Create (P, Stream.Implementation_Pointer (PI));
      end;
   end Set_Input;

   procedure Fetch (Stream : in out Implementation; E : out Event) is
   begin
      while not Stream.Levels.Top.State (Stream, E) loop
         null;
      end loop;
   end Fetch;

   function Current_Lexer_Token_Start (P : Reference) return Mark is
     (Lexer.Recent_Start_Mark (Implementation_Pointer (P.Implementation_Access).L));

   function Current_Input_Character (P : Reference) return Mark is
     (Lexer.Cur_Mark (Implementation_Pointer (P.Implementation_Access).L));

   function Recent_Lexer_Token_Start (P : Reference) return Mark is
     (Implementation_Pointer (P.Implementation_Access).Current.Start_Pos);

   function Recent_Lexer_Token_End (P : Reference) return Mark is
     (Implementation_Pointer (P.Implementation_Access).Current.End_Pos);

   -----------------------------------------------------------------------------
   --                   internal utility subroutines
   -----------------------------------------------------------------------------

   procedure Reset_Tag_Handles (P : in out Implementation'Class) is
   begin
      Tag_Handle_Sets.Clear (P.Tag_Handles);
      pragma Warnings (Off);
      if P.Tag_Handles.Set ("!", P.Pool.From_String ("!")) and
        P.Tag_Handles.Set ("!!",
                           P.Pool.From_String ("tag:yaml.org,2002:"))
      then
         null;
      end if;
      pragma Warnings (On);
   end Reset_Tag_Handles;

   function Parse_Tag (P : in out Implementation'Class)
                       return Text.Reference is
      use type Ada.Containers.Hash_Type;
      Tag_Handle : constant String := Lexer.Full_Lexeme (P.L);
      Holder : constant access constant Tag_Handle_Sets.Holder :=
        P.Tag_Handles.Get (Tag_Handle, False);
   begin
      if Holder.Hash = 0 then
         raise Parser_Error with
           "Unknown tag handle: " & Tag_Handle;
      end if;
      P.Current := Lexer.Next_Token (P.L);
      if P.Current.Kind /= Lexer.Tag_Uri then
         raise Parser_Error with "Unexpected token (expected tag suffix): " &
           P.Current.Kind'Img;
      end if;
      return P.Pool.From_String (Holder.Value & Lexer.Current_Content (P.L));
   end Parse_Tag;

   function To_Style (T : Lexer.Scalar_Token_Kind)
                      return Scalar_Style_Type is
     (case T is
         when Lexer.Plain_Scalar => Plain,
         when Lexer.Single_Quoted_Scalar => Single_Quoted,
         when Lexer.Double_Quoted_Scalar => Double_Quoted,
         when Lexer.Literal_Scalar => Literal,
         when Lexer.Folded_Scalar => Folded) with Inline;

   -----------------------------------------------------------------------------
   --                        state implementations
   -----------------------------------------------------------------------------

   function At_Stream_Start (P : in out Implementation'Class;
                             E : out Event) return Boolean is
   begin
      P.Levels.Top.all := (State => At_Stream_End'Access, Indentation => -2);
      P.Levels.Push ((State => Before_Doc'Access, Indentation => -1));
      E := Event'(Kind => Stream_Start,
                         Start_Position => (Line => 1, Column => 1, Index => 1),
                         End_Position => (Line => 1, Column => 1, Index => 1));
      P.Current := Lexer.Next_Token (P.L);
      Reset_Tag_Handles (P);
      return True;
   end At_Stream_Start;

   function At_Stream_End (P : in out Implementation'Class;
                           E : out Event) return Boolean is
      T : constant Lexer.Token := Lexer.Next_Token (P.L);
   begin
      E := Event'(Kind => Stream_End,
                         Start_Position => T.Start_Pos,
                         End_Position => T.End_Pos);
      return True;
   end At_Stream_End;

   function Before_Doc (P : in out Implementation'Class;
                         E : out Event) return Boolean is
      Version : Text.Reference := Text.Empty;
   begin
      case P.Current.Kind is
         when Lexer.Document_End =>
            Reset_Tag_Handles (P);
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Directives_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position => P.Current.End_Pos,
                               Kind => Document_Start,
                               Implicit_Start => False,
                               Version => Version);
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Top.State := Before_Doc_End'Access;
            P.Levels.Push ((State => After_Directives_End'Access,
                              Indentation => -1));
            return True;
         when Lexer.Stream_End =>
            P.Levels.Pop;
            return False;
         when Lexer.Indentation =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Document_Start,
                               Implicit_Start => True,
                               Version => Version);
            P.Levels.Top.State := Before_Doc_End'Access;
            P.Levels.Push ((State => Before_Implicit_Root'Access,
                              Indentation => -1));
            return True;
         when Lexer.Yaml_Directive =>
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind /= Lexer.Directive_Param then
               raise Parser_Error with
                 "Invalid token (expected YAML version string): " &
                 P.Current.Kind'Img;
            elsif Version /= Text.Empty then
               raise Parser_Error with
                 "Duplicate YAML directive";
            end if;
            Version := P.Pool.From_String (Lexer.Full_Lexeme (P.L));
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Tag_Directive =>
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind /= Lexer.Tag_Handle then
               raise Parser_Error with
                 "Invalid token (expected tag handle): " & P.Current.Kind'Img;
            end if;
            declare
               Tag_Handle : constant String := Lexer.Full_Lexeme (P.L);
               Holder : access Tag_Handle_Sets.Holder;
            begin
               P.Current := Lexer.Next_Token (P.L);
               if P.Current.Kind /= Lexer.Tag_Uri then
                  raise Parser_Error with
                    "Invalid token (expected tag URI): " & P.Current.Kind'Img;
               end if;
               if Tag_Handle = "!" or Tag_Handle = "!!" then
                  Holder := Tag_Handle_Sets.Get (P.Tag_Handles, Tag_Handle, False);
                  Holder.Value := Lexer.Current_Content (P.L);
               else
                  if not Tag_Handle_Sets.Set (P.Tag_Handles, Tag_Handle,
                                              Lexer.Current_Content (P.L)) then
                     raise Parser_Error with
                       "Redefinition of tag handle " & Tag_Handle;
                  end if;
               end if;
            end;
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Unknown_Directive =>
            raise Parser_Error with "Not implemented: unknown directives";
         when others =>
            raise Parser_Error with
              "Unexpected token (expected directive or document start): " &
              P.Current.Kind'Img;
      end case;
   end Before_Doc;

   function After_Directives_End (P : in out Implementation'Class;
                                  E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Node_Property_Kind =>
            P.Inline_Start := P.Current.Start_Pos;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                              Indentation => <>));
            return False;
         when Lexer.Indentation =>
            P.Header_Start := P.Inline_Start;
            P.Levels.Top.State := At_Block_Indentation'Access;
            return False;
         when Lexer.Document_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Levels.Pop;
            return True;
         when Lexer.Folded_Scalar | Lexer.Literal_Scalar =>
            E := Event'(
              Start_Position => P.Current.Start_Pos,
              End_Position   => P.Current.End_Pos,
              Kind => Scalar,
              Scalar_Properties => P.Inline_Props,
              Scalar_Style => (if P.Current.Kind = Lexer.Folded_Scalar then
                                  Folded else Literal),
              Content => Lexer.Current_Content (P.L));
            P.Levels.Pop;
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when others =>
            raise Parser_Error with "Illegal content at '---' line: " &
              P.Current.Kind'Img;
      end case;
   end After_Directives_End;

   function Before_Implicit_Root (P : in out Implementation'Class;
                                  E : out Event) return Boolean is
      pragma Unreferenced (E);
   begin
      if P.Current.Kind /= Lexer.Indentation then
         raise Parser_Error with "Unexpected token (expected line start) :" &
           P.Current.Kind'Img;
      end if;
      P.Inline_Start := P.Current.End_Pos;
      P.Levels.Top.Indentation := Lexer.Recent_Indentation (P.L);
      P.Current := Lexer.Next_Token (P.L);
      case P.Current.Kind is
         when Lexer.Seq_Item_Ind | Lexer.Map_Key_Ind | Lexer.Map_Value_Ind =>
            P.Levels.Top.State := After_Block_Parent'Access;
            return False;
         when Lexer.Scalar_Token_Kind =>
            P.Levels.Top.State := Require_Implicit_Map_Start'Access;
            return False;
         when Lexer.Node_Property_Kind =>
            P.Levels.Top.State := Require_Implicit_Map_Start'Access;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                            Indentation => <>));
            return False;
         when Lexer.Flow_Map_Start | Lexer.Flow_Seq_Start =>
            P.Levels.Top.State := After_Block_Parent_Props'Access;
            return False;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected collection start): " &
              P.Current.Kind'Img;
      end case;
   end Before_Implicit_Root;

   function Require_Implicit_Map_Start (P : in out Implementation'Class;
                                        E : out Event) return Boolean is
      Header_End : Mark;
   begin
      P.Levels.Top.Indentation := Lexer.Recent_Indentation (P.L);
      case P.Current.Kind is
         when Lexer.Alias =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Alias,
                               Target => P.Pool.From_String (Lexer.Short_Lexeme (P.L)));
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               P.Cached := E;
               E := Event'(Start_Position => P.Header_Start,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => P.Header_Props,
                                  Collection_Style => Block);
               P.Header_Props := (others => <>);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            else
               if not Is_Empty (P.Header_Props) then
                  raise Parser_Error with "Alias may not have properties";
               end if;
               --  alias is allowed on document root without '---'
               P.Levels.Pop;
            end if;
            return True;
         when Lexer.Flow_Scalar_Token_Kind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => To_Style (P.Current.Kind),
                               Content => Lexer.Current_Content (P.L));
            P.Inline_Props := (others => <>);
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               if Lexer.Last_Scalar_Was_Multiline (P.L) then
                  raise Parser_Error with
                    "Implicit mapping key may not be multiline";
               end if;
               P.Cached := E;
               E := Event'(Start_Position => P.Header_Start,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => P.Header_Props,
                                  Collection_Style => Block);
               P.Header_Props := (others => <>);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            elsif P.Current.Kind in Lexer.Indentation | Lexer.Document_End |
              Lexer.Directives_End | Lexer.Stream_End then
               raise Parser_Error with "Scalar at root level requires '---'.";
            end if;
            return True;
         when Lexer.Flow_Map_Start | Lexer.Flow_Seq_Start =>
            P.Levels.Top.State := Before_Flow_Item_Props'Access;
            return False;
         when Lexer.Indentation =>
              raise Parser_Error with
                "Stand-alone node properties not allowed on non-header line";
         when others =>
            raise Parser_Error with
              "Unexpected token (expected implicit mapping key): " &
              P.Current.Kind'Img;
      end case;
   end Require_Implicit_Map_Start;

   function At_Block_Indentation (P : in out Implementation'Class;
                                  E : out Event) return Boolean is
      Header_End : Mark;
   begin
      if P.Current.Kind /= Lexer.Indentation then
         raise Parser_Error with "Unexpected token (expected line start): " &
           P.Current.Kind'Img;
      end if;
      P.Block_Indentation := Lexer.Current_Indentation (P.L);
      P.Current := Lexer.Next_Token (P.L);
      if P.Block_Indentation < P.Levels.Top.Indentation or else
        (P.Block_Indentation = P.Levels.Top.Indentation and then
         (P.Current.Kind /= Lexer.Seq_Item_Ind or else
          P.Levels.Element (P.Levels.Length - 1).State = In_Block_Seq'Access))
      then
         -- empty element is empty scalar
         E := Event'(Start_Position => P.Header_Start,
                            End_Position   => P.Header_Start,
                            Kind => Scalar,
                            Scalar_Properties => P.Header_Props,
                            Scalar_Style => Plain,
                            Content => Text.Empty);
         P.Header_Props := (others => <>);
         P.Levels.Pop;
         return True;
      end if;
      P.Inline_Start := P.Current.Start_Pos;
      case P.Current.Kind is
         when Lexer.Node_Property_Kind =>
            if Is_Empty (P.Header_Props) then
               P.Levels.Top.State := Require_Inline_Block_Item'Access;
            else
               P.Levels.Top.State := Require_Implicit_Map_Start'Access;
            end if;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                            Indentation => <>));
            return False;
         when Lexer.Seq_Item_Ind =>
            E := Event'(Start_Position => P.Header_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Block);
            P.Header_Props := (others => <>);
            P.Levels.Top.all := (State => In_Block_Seq'Access,
                                 Indentation => Lexer.Recent_Indentation (P.L));
            P.Levels.Push ((State => After_Block_Parent'Access,
                            Indentation => Lexer.Recent_Indentation (P.L)));
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when Lexer.Map_Key_Ind =>
            E := Event'(Start_Position => P.Header_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Block);
            P.Header_Props := (others => <>);
            P.Levels.Top.all := (State => Before_Block_Map_Value'Access,
                                 Indentation => Lexer.Recent_Indentation (P.L));
            P.Levels.Push ((State => After_Block_Parent'Access,
                            Indentation => Lexer.Recent_Indentation (P.L)));
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when Lexer.Flow_Scalar_Token_Kind =>
            P.Levels.Top.Indentation := Lexer.Recent_Indentation (P.L);
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Header_Props,
                               Scalar_Style => To_Style (P.Current.Kind),
                               Content => Lexer.Current_Content (P.L));
            P.Header_Props := (others => <>);
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               if Lexer.Last_Scalar_Was_Multiline (P.L) then
                  raise Parser_Error with
                    "Implicit mapping key may not be multiline";
               end if;
               P.Cached := E;
               E := Event'(Start_Position => P.Header_Start,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => P.Cached.Scalar_Properties,
                                  Collection_Style => Block);
               P.Cached.Scalar_Properties := (others => <>);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            else
               P.Levels.Pop;
            end if;
            return True;
         when others =>
            P.Levels.Top.State := At_Block_Indentation_Props'Access;
            return False;
      end case;
   end At_Block_Indentation;

   function At_Block_Indentation_Props (P : in out Implementation'Class;
                                        E : out Event) return Boolean is
      Header_End : Mark;
   begin
      P.Levels.Top.Indentation := Lexer.Recent_Indentation (P.L);
      case P.Current.Kind is
         when Lexer.Map_Value_Ind =>
            P.Cached := Event'(Start_Position => P.Inline_Start,
                                      End_Position   => P.Current.End_Pos,
                                      Kind => Scalar,
                                      Scalar_Properties => P.Inline_Props,
                                      Scalar_Style => Plain,
                                      Content => Text.Empty);
            P.Inline_Props := (others => <>);
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Block);
            P.Header_Props := (others => <>);
            P.Levels.Top.State := After_Implicit_Map_Start'Access;
            return True;
         when Lexer.Flow_Scalar_Token_Kind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => To_Style (P.Current.Kind),
                               Content => Lexer.Current_Content (P.L));
            P.Inline_Props := (others => <>);
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               if Lexer.Last_Scalar_Was_Multiline (P.L) then
                  raise Parser_Error with
                    "Implicit mapping key may not be multiline";
               end if;
               P.Cached := E;
               E := Event'(Start_Position => P.Header_Start,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => P.Header_Props,
                                  Collection_Style => Block);
               P.Header_Props := (others => <>);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            else
               P.Levels.Pop;
            end if;
            return True;
         when Lexer.Alias =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Alias,
                               Target => P.Pool.From_String (Lexer.Short_Lexeme (P.L)));
            P.Inline_Props := (others => <>);
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               P.Cached := E;
               E := Event'(Start_Position => P.Header_Start,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => P.Header_Props,
                                  Collection_Style => Block);
               P.Header_Props := (others => <>);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            elsif not Is_Empty (P.Header_Props) then
               raise Parser_Error with "Alias may not have properties";
            else
               P.Levels.Pop;
            end if;
            return True;
         when Lexer.Flow_Map_Start =>
            E := Event'(Start_Position => P.Header_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Flow);
            P.Header_Props := (others => <>);
            P.Levels.Top.State := After_Flow_Map_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when Lexer.Flow_Seq_Start =>
            E := Event'(Start_Position => P.Header_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Flow);
            P.Header_Props := (others => <>);
            P.Levels.Top.State := After_Flow_Seq_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected block content): " &
              P.Current.Kind'Img;
      end case;
   end At_Block_Indentation_Props;

   function Before_Node_Properties (P : in out Implementation'Class;
                                    E : out Event) return Boolean is
      pragma Unreferenced (E);
   begin
      case P.Current.Kind is
         when Lexer.Tag_Handle =>
            if P.Inline_Props.Tag /= Text.Empty then
               raise Parser_Error with "Only one tag allowed per element";
            end if;
            P.Inline_Props.Tag := Parse_Tag (P);
         when Lexer.Verbatim_Tag =>
            if P.Inline_Props.Tag /= Text.Empty then
               raise Parser_Error with "Only one tag allowed per element";
            end if;
            P.Inline_Props.Tag := Lexer.Current_Content (P.L);
         when Lexer.Anchor =>
            if P.Inline_Props.Anchor /= Text.Empty then
               raise Parser_Error with "Only one anchor allowed per element";
            end if;
            P.Inline_Props.Anchor :=
              P.Pool.From_String (Lexer.Short_Lexeme (P.L));
         when Lexer.Annotation =>
            E := Event'(Start_Position => P.Inline_Start,
                        End_Position => P.Current.Start_Pos,
                        Kind => Annotation_Start,
                        Annotation_Properties => P.Inline_Props,
                        Name => P.Pool.From_String (Lexer.Short_Lexeme (P.L)));
            P.Inline_Props := (others => <>);
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Params_Start then
               P.Current := Lexer.Next_Token (P.L);
               P.Levels.Push ((State => After_Param_Sep'Access,
                               Indentation => P.Block_Indentation));
            else
               P.Levels.Top.State := After_Annotation'Access;
            end if;
            return True;
         when Lexer.Indentation =>
            P.Header_Props := P.Inline_Props;
            P.Inline_Props := (others => <>);
            P.Levels.Pop;
            return False;
         when Lexer.Alias =>
            raise Parser_Error with "Alias may not have properties";
         when others =>
            P.Levels.Pop;
            return False;
      end case;
      P.Current := Lexer.Next_Token (P.L);
      return False;
   end Before_Node_Properties;

   function After_Block_Parent (P : in out Implementation'Class;
                                E : out Event) return Boolean is
   begin
      P.Inline_Start := P.Current.Start_Pos;
      case P.Current.Kind is
         when Lexer.Node_Property_Kind =>
            P.Levels.Top.State := After_Block_Parent_Props'Access;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                            Indentation => <>));
         when Lexer.Seq_Item_Ind =>
            E := Event'(Start_Position => P.Header_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Block);
            P.Header_Props := (others => <>);
            P.Levels.Top.all := (State => In_Block_Seq'Access,
                                 Indentation => Lexer.Recent_Indentation (P.L));
            P.Levels.Push ((State => After_Block_Parent'Access,
                            Indentation => Lexer.Recent_Indentation (P.L)));
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when Lexer.Map_Key_Ind =>
            E := Event'(Start_Position => P.Header_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => P.Header_Props,
                               Collection_Style => Block);
            P.Header_Props := (others => <>);
            P.Levels.Top.all := (State => Before_Block_Map_Value'Access,
                                 Indentation => Lexer.Recent_Indentation (P.L));
            P.Levels.Push ((State => After_Block_Parent'Access,
                            Indentation => Lexer.Recent_Indentation (P.L)));
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when others =>
            P.Levels.Top.State := After_Block_Parent_Props'Access;
            return False;
      end case;
      return False;
   end After_Block_Parent;

   function After_Block_Parent_Props (P : in out Implementation'Class;
                                      E : out Event) return Boolean is
      Header_End : Mark;
   begin
      P.Levels.Top.Indentation := Lexer.Recent_Indentation (P.L);
      case P.Current.Kind is
         when Lexer.Indentation =>
            P.Header_Start := P.Inline_Start;
            P.Levels.Top.all :=
              (State => At_Block_Indentation'Access,
               Indentation => P.Levels.Element (P.Levels.Length - 1).Indentation);
            return False;
         when Lexer.Stream_End | Lexer.Document_End | Lexer.Directives_End =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position => P.Current.Start_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Inline_Props := (others => <>);
            P.Levels.Pop;
            return True;
         when Lexer.Map_Value_Ind =>
            P.Cached := Event'(Start_Position => P.Inline_Start,
                                      End_Position   => P.Current.End_Pos,
                                      Kind => Scalar,
                                      Scalar_Properties => P.Inline_Props,
                                      Scalar_Style => Plain,
                                      Content => Text.Empty);
            P.Inline_Props := (others => <>);
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.Start_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => (others => <>),
                               Collection_Style => Block);
            P.Levels.Top.State := After_Implicit_Map_Start'Access;
            return True;
         when Lexer.Alias =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Alias,
                               Target => P.Pool.From_String (Lexer.Short_Lexeme (P.L)));
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               P.Cached := E;
               E := Event'(Start_Position => Header_End,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => (others => <>),
                                  Collection_Style => Block);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            else
               P.Levels.Pop;
            end if;
            return True;
         when Lexer.Scalar_Token_Kind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => To_Style (P.Current.Kind),
                               Content => Lexer.Current_Content (P.L));
            P.Inline_Props := (others => <>);
            Header_End := P.Current.Start_Pos;
            P.Current := Lexer.Next_Token (P.L);
            if P.Current.Kind = Lexer.Map_Value_Ind then
               if Lexer.Last_Scalar_Was_Multiline (P.L) then
                  raise Parser_Error with
                    "Implicit mapping key may not be multiline";
               end if;
               P.Cached := E;
               E := Event'(Start_Position => Header_End,
                                  End_Position   => Header_End,
                                  Kind => Mapping_Start,
                                  Collection_Properties => (others => <>),
                                  Collection_Style => Block);
               P.Levels.Top.State := After_Implicit_Map_Start'Access;
            else
               P.Levels.Pop;
            end if;
            return True;
         when Lexer.Flow_Map_Start =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => P.Inline_Props,
                               Collection_Style => Flow);
            P.Inline_Props := (others => <>);
            P.Levels.Top.State := After_Flow_Map_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when Lexer.Flow_Seq_Start =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_Start,
                               Collection_Properties => P.Inline_Props,
                               Collection_Style => Flow);
            P.Inline_Props := (others => <>);
            P.Levels.Top.State := After_Flow_Seq_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected newline or flow item start): " &
              P.Current.Kind'Img;
      end case;
   end After_Block_Parent_Props;

   function Require_Inline_Block_Item (P : in out Implementation'Class;
                                       E : out Event) return Boolean is
      pragma Unreferenced (E);
   begin
      P.Levels.Top.Indentation := Lexer.Recent_Indentation (P.L);
      case P.Current.Kind is
         when Lexer.Indentation =>
            raise Parser_Error with
              "Node properties may not stand alone on a line";
         when others =>
            P.Levels.Top.State := After_Block_Parent_Props'Access;
            return False;
      end case;
   end Require_Inline_Block_Item;

   function Before_Doc_End (P : in out Implementation'Class;
                               E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Document_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Document_End,
                               Implicit_End => False);
            P.Levels.Top.State := Before_Doc'Access;
            Reset_Tag_Handles (P);
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Stream_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Document_End,
                               Implicit_End => True);
            P.Levels.Pop;
         when Lexer.Directives_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Document_End,
                               Implicit_End => True);
            Reset_Tag_Handles (P);
            P.Levels.Top.State := Before_Doc'Access;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected document end): " & P.Current.Kind'Img;
      end case;
      return True;
   end Before_Doc_End;

   function In_Block_Seq (P : in out Implementation'Class;
                          E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Indentation =>
            P.Block_Indentation := Lexer.Current_Indentation (P.L);
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Document_End | Lexer.Directives_End | Lexer.Stream_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_End);
            P.Levels.Pop;
            return True;
         when others => null;
      end case;
      if P.Block_Indentation < P.Levels.Top.Indentation then
          E := Event'(Start_Position => P.Current.Start_Pos,
                             End_Position   => P.Current.Start_Pos,
                             Kind => Sequence_End);
          P.Levels.Pop;
          return True;
      elsif P.Block_Indentation > P.Levels.Top.Indentation then
         raise Parser_Error with "Invalid indentation (bseq); got" &
           P.Block_Indentation'Img & ", expected" & P.Levels.Top.Indentation'Img;
      end if;
      case P.Current.Kind is
         when Lexer.Seq_Item_Ind =>
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Push
              ((State => After_Block_Parent'Access, Indentation => P.Block_Indentation));
            return False;
         when others =>
            if P.Levels.Element (P.Levels.Length - 1).Indentation =
              P.Levels.Top.Indentation then
               E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_End);
               P.Levels.Pop;
               return True;
            else
               raise Parser_Error with
                 "Illegal token (expected block sequence indicator): " &
                 P.Current.Kind'Img;
            end if;
      end case;
   end In_Block_Seq;

   function After_Implicit_Map_Start (P : in out Implementation'Class;
                                      E : out Event) return Boolean is
   begin
      E := P.Cached;
      P.Levels.Top.State := After_Implicit_Key'Access;
      return True;
   end After_Implicit_Map_Start;

   function Before_Block_Map_Key (P : in out Implementation'Class;
                                  E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Indentation =>
            P.Block_Indentation := Lexer.Current_Indentation (P.L);
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Document_End | Lexer.Directives_End | Lexer.Stream_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_End);
            P.Levels.Pop;
            return True;
         when others => null;
      end case;
      if P.Block_Indentation < P.Levels.Top.Indentation then
          E := Event'(Start_Position => P.Current.Start_Pos,
                             End_Position   => P.Current.End_Pos,
                             Kind => Mapping_End);
          P.Levels.Pop;
          return True;
      elsif P.Block_Indentation > P.Levels.Top.Indentation then
         raise Parser_Error with "Invalid indentation (bmk); got" &
           P.Block_Indentation'Img & ", expected" & P.Levels.Top.Indentation'Img &
         ", token = " & P.Current.Kind'Img;
      end if;
      case P.Current.Kind is
         when Lexer.Map_Key_Ind =>
            P.Levels.Top.State := Before_Block_Map_Value'Access;
            P.Levels.Push
              ((State => After_Block_Parent'Access,
                Indentation => P.Levels.Top.Indentation));
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Node_Property_Kind =>
            P.Levels.Top.State := At_Block_Map_Key_Props'Access;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                            Indentation => <>));
            return False;
         when Lexer.Flow_Scalar_Token_Kind | Lexer.Alias =>
            P.Levels.Top.State := At_Block_Map_Key_Props'Access;
            return False;
         when Lexer.Map_Value_Ind =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => (others => <>),
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Levels.Top.State := Before_Block_Map_Value'Access;
            return True;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected mapping key): " &
              P.Current.Kind'Img;
      end case;
   end Before_Block_Map_Key;

   function At_Block_Map_Key_Props (P : in out Implementation'Class;
                                    E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Alias =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Alias,
                               Target => P.Pool.From_String (Lexer.Short_Lexeme (P.L)));
         when Lexer.Flow_Scalar_Token_Kind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => To_Style (P.Current.Kind),
                               Content => Lexer.Current_Content (P.L));
            P.Inline_Props := (others => <>);
            if Lexer.Last_Scalar_Was_Multiline (P.L) then
               raise Parser_Error with
                 "Implicit mapping key may not be multiline";
            end if;
         when Lexer.Map_Value_Ind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.Start_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Inline_Props := (others => <>);
            P.Levels.Top.State := After_Implicit_Key'Access;
            return True;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected implicit mapping key): " &
              P.Current.Kind'Img;
      end case;
      P.Current := Lexer.Next_Token (P.L);
      P.Levels.Top.State := After_Implicit_Key'Access;
      return True;
   end At_Block_Map_Key_Props;

   function After_Implicit_Key (P : in out Implementation'Class;
                                E : out Event) return Boolean is
      pragma Unreferenced (E);
   begin
      if P.Current.Kind /= Lexer.Map_Value_Ind then
         raise Parser_Error with "Unexpected token (expected ':'): " &
           P.Current.Kind'Img;
      end if;
      P.Current := Lexer.Next_Token (P.L);
      P.Levels.Top.State := Before_Block_Map_Key'Access;
      P.Levels.Push
        ((State => After_Block_Parent'Access,
          Indentation => P.Levels.Top.Indentation));
      return False;
   end After_Implicit_Key;

   function Before_Block_Map_Value (P : in out Implementation'Class;
                                    E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Indentation =>
            P.Block_Indentation := Lexer.Current_Indentation (P.L);
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Document_End | Lexer.Directives_End | Lexer.Stream_End =>
            --  the value is allowed to be missing after an explicit key
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => (others => <>),
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Levels.Top.State := Before_Block_Map_Key'Access;
            return True;
         when others => null;
      end case;
      if P.Block_Indentation < P.Levels.Top.Indentation then
          --  the value is allowed to be missing after an explicit key
          E := Event'(Start_Position => P.Current.Start_Pos,
                             End_Position   => P.Current.End_Pos,
                             Kind => Scalar,
                             Scalar_Properties => (others => <>),
                             Scalar_Style => Plain,
                             Content => Text.Empty);
          P.Levels.Top.State := Before_Block_Map_Key'Access;
          return True;
      elsif P.Block_Indentation > P.Levels.Top.Indentation then
         raise Parser_Error with "Invalid indentation (bmv)";
      end if;
      case P.Current.Kind is
         when Lexer.Map_Value_Ind =>
            P.Levels.Top.State := Before_Block_Map_Key'Access;
            P.Levels.Push
              ((State => After_Block_Parent'Access,
                Indentation => P.Levels.Top.Indentation));
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Map_Key_Ind | Lexer.Flow_Scalar_Token_Kind |
            Lexer.Node_Property_Kind =>
            --  the value is allowed to be missing after an explicit key
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => (others => <>),
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Levels.Top.State := Before_Block_Map_Key'Access;
            return True;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected mapping value): " &
              P.Current.Kind'Img;
      end case;
   end Before_Block_Map_Value;

   function Before_Flow_Item (P : in out Implementation'Class;
                              E : out Event) return Boolean is
   begin
      P.Inline_Start := P.Current.Start_Pos;
      case P.Current.Kind is
         when Lexer.Node_Property_Kind =>
            P.Levels.Top.State := Before_Flow_Item_Props'Access;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                            Indentation => <>));
         when Lexer.Alias =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Alias,
                               Target => P.Pool.From_String (Lexer.Short_Lexeme (P.L)));
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Pop;
            return True;
         when others =>
            P.Levels.Top.State := Before_Flow_Item_Props'Access;
      end case;
      return False;
   end Before_Flow_Item;

   function Before_Flow_Item_Props (P : in out Implementation'Class;
                                    E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Scalar_Token_Kind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => To_Style (P.Current.Kind),
                               Content => Lexer.Current_Content (P.L));
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Pop;
         when Lexer.Flow_Map_Start =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => P.Inline_Props,
                               Collection_Style => Flow);
            P.Levels.Top.State := After_Flow_Map_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Flow_Seq_Start =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_Start,
                               Collection_Properties => P.Inline_Props,
                               Collection_Style => Flow);
            P.Levels.Top.State := After_Flow_Seq_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Flow_Map_End | Lexer.Flow_Seq_End |
              Lexer.Flow_Separator | Lexer.Map_Value_Ind =>
            E := Event'(Start_Position => P.Inline_Start,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => P.Inline_Props,
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Levels.Pop;
         when others =>
            raise Parser_Error with
              "Unexpected token (expected flow node): " & P.Current.Kind'Img;
      end case;
      P.Inline_Props := (others => <>);
      return True;
   end Before_Flow_Item_Props;

   function After_Flow_Map_Key (P : in out Implementation'Class;
                                E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Map_Value_Ind =>
            P.Levels.Top.State := After_Flow_Map_Value'Access;
            P.Levels.Push ((State => Before_Flow_Item'Access, others => <>));
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Flow_Separator | Lexer.Flow_Map_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Scalar,
                               Scalar_Properties => (others => <>),
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Levels.Top.State := After_Flow_Map_Value'Access;
            return True;
         when others =>
            raise Parser_Error with "Unexpected token (expected ':'): " &
              P.Current.Kind'Img;
      end case;
   end After_Flow_Map_Key;

   function After_Flow_Map_Value (P : in out Implementation'Class;
                                  E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Flow_Separator =>
            P.Levels.Top.State := After_Flow_Map_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Flow_Map_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_End);
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Pop;
            return True;
         when Lexer.Flow_Scalar_Token_Kind | Lexer.Map_Key_Ind |
              Lexer.Anchor | Lexer.Alias | Lexer.Annotation |
              Lexer.Flow_Map_Start | Lexer.Flow_Seq_Start =>
            raise Parser_Error with "Missing ','";
         when others =>
            raise Parser_Error with "Unexpected token (expected ',' or '}'): " &
              P.Current.Kind'Img;
      end case;
   end After_Flow_Map_Value;

   function After_Flow_Seq_Item (P : in out Implementation'Class;
                                 E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Flow_Separator =>
            P.Levels.Top.State := After_Flow_Seq_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Flow_Seq_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Sequence_End);
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Pop;
            return True;
         when Lexer.Flow_Scalar_Token_Kind | Lexer.Map_Key_Ind |
              Lexer.Anchor | Lexer.Alias | Lexer.Annotation |
              Lexer.Flow_Map_Start | Lexer.Flow_Seq_Start =>
            raise Parser_Error with "Missing ','";
         when others =>
            raise Parser_Error with "Unexpected token (expected ',' or ']'): " &
              P.Current.Kind'Img;
      end case;
   end After_Flow_Seq_Item;

   function After_Flow_Map_Sep (P : in out Implementation'Class;
                                E : out Event) return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Map_Key_Ind =>
            P.Current := Lexer.Next_Token (P.L);
         when Lexer.Flow_Map_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_End);
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Pop;
            return True;
         when others => null;
      end case;
      P.Levels.Top.State := After_Flow_Map_Key'Access;
      P.Levels.Push ((State => Before_Flow_Item'Access, Indentation => <>));
      return False;
   end After_Flow_Map_Sep;

   function Possible_Next_Sequence_Item (P : in out Implementation'Class;
                                         E : out Event;
                                         End_Token : Lexer.Token_Kind;
                                         After_Props, After_Item : State_Type)
                                         return Boolean is
   begin
      P.Inline_Start := P.Current.Start_Pos;
      case P.Current.Kind is
         when Lexer.Flow_Separator =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.Start_Pos,
                               Kind => Scalar,
                               Scalar_Properties => (others => <>),
                               Scalar_Style => Plain,
                               Content => Text.Empty);
            P.Current := Lexer.Next_Token (P.L);
            return True;
         when Lexer.Node_Property_Kind =>
            P.Levels.Top.State := After_Props;
            P.Levels.Push ((State => Before_Node_Properties'Access,
                            Indentation => <>));
            return False;
         when Lexer.Flow_Scalar_Token_Kind =>
            P.Levels.Top.State := After_Props;
            return False;
         when Lexer.Map_Key_Ind =>
            P.Levels.Top.State := After_Item;
            E := Event'(Start_Position => P.Current.Start_Pos,
                               End_Position   => P.Current.End_Pos,
                               Kind => Mapping_Start,
                               Collection_Properties => (others => <>),
                               Collection_Style => Flow);
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Push ((State => Before_Pair_Value'Access, others => <>));
            P.Levels.Push ((State => Before_Flow_Item'Access, others => <>));
            return True;
         when others =>
            if P.Current.Kind = End_Token then
               E := Event'(Start_Position => P.Current.Start_Pos,
                           End_Position   => P.Current.End_Pos,
                           Kind => Sequence_End);
               P.Current := Lexer.Next_Token (P.L);
               P.Levels.Pop;
               return True;
            else
               P.Levels.Top.State := After_Item;
               P.Levels.Push ((State => Before_Flow_Item'Access, others => <>));
               return False;
            end if;
      end case;
   end Possible_Next_Sequence_Item;


   function After_Flow_Seq_Sep (P : in out Implementation'Class;
                                E : out Event) return Boolean is
   begin
      return Possible_Next_Sequence_Item (P, E, Lexer.Flow_Seq_End,
                                          After_Flow_Seq_Sep_Props'Access,
                                          After_Flow_Seq_Item'Access);
   end After_Flow_Seq_Sep;

   function Forced_Next_Sequence_Item (P : in out Implementation'Class;
                                       E : out Event) return Boolean is
   begin
      if P.Current.Kind in Lexer.Flow_Scalar_Token_Kind then
         E := Event'(Start_Position => P.Inline_Start,
                     End_Position   => P.Current.End_Pos,
                     Kind => Scalar,
                     Scalar_Properties => P.Inline_Props,
                     Scalar_Style => To_Style (P.Current.Kind),
                     Content => Lexer.Current_Content (P.L));
         P.Inline_Props := (others => <>);
         P.Current := Lexer.Next_Token (P.L);
         if P.Current.Kind = Lexer.Map_Value_Ind then
            P.Cached := E;
            E := Event'(Start_Position => P.Current.Start_Pos,
                        End_Position   => P.Current.Start_Pos,
                        Kind => Mapping_Start,
                        Collection_Properties => (others => <>),
                        Collection_Style => Flow);

            P.Levels.Push ((State => After_Implicit_Pair_Start'Access,
                            Indentation => <>));
         end if;
         return True;
      else
         P.Levels.Push ((State => Before_Flow_Item_Props'Access, others => <>));
         return False;
      end if;
   end Forced_Next_Sequence_Item;

   function After_Flow_Seq_Sep_Props (P : in out Implementation'Class;
                                      E : out Event) return Boolean is
   begin
      P.Levels.Top.State := After_Flow_Seq_Item'Access;
      return Forced_Next_Sequence_Item (P, E);
   end After_Flow_Seq_Sep_Props;

   function Before_Pair_Value (P : in out Implementation'Class;
                               E : out Event) return Boolean is
   begin
      if P.Current.Kind = Lexer.Map_Value_Ind then
         P.Levels.Top.State := After_Pair_Value'Access;
         P.Levels.Push ((State => Before_Flow_Item'Access, others => <>));
         P.Current := Lexer.Next_Token (P.L);
         return False;
      else
         --  pair ends here without value.
         E := Event'(Start_Position => P.Current.Start_Pos,
                            End_Position   => P.Current.End_Pos,
                            Kind => Scalar,
                            Scalar_Properties => (others => <>),
                            Scalar_Style => Plain,
                            Content => Text.Empty);
         P.Levels.Pop;
         return True;
      end if;
   end Before_Pair_Value;

   function After_Implicit_Pair_Start (P : in out Implementation'Class;
                                       E : out Event) return Boolean is
   begin
      E := P.Cached;
      P.Current := Lexer.Next_Token (P.L);
      P.Levels.Top.State := After_Pair_Value'Access;
      P.Levels.Push ((State => Before_Flow_Item'Access, others => <>));
      return True;
   end After_Implicit_Pair_Start;

   function After_Pair_Value (P : in out Implementation'Class;
                              E : out Event) return Boolean is
   begin
      E := Event'(Start_Position => P.Current.Start_Pos,
                         End_Position   => P.Current.End_Pos,
                         Kind => Mapping_End);
      P.Levels.Pop;
      return True;
   end After_Pair_Value;

   procedure Close_Stream (Stream : in out Implementation) is
   begin
      Lexer.Finish (Stream.L);
   end Close_Stream;

   function After_Param_Sep (P : in out Implementation'Class; E : out Event)
                             return Boolean is
   begin
      return Possible_Next_Sequence_Item (P, E, Lexer.Params_End,
                                          After_Param_Sep_Props'Access,
                                          After_Param'Access);
   end After_Param_Sep;

   function After_Param_Sep_Props
     (P : in out Implementation'Class; E : out Event) return Boolean is
   begin
      P.Levels.Top.State := After_Param'Access;
      return Forced_Next_Sequence_Item (P, E);
   end After_Param_Sep_Props;

   function After_Param (P : in out Implementation'Class; E : out Event)
                         return Boolean is
   begin
      case P.Current.Kind is
         when Lexer.Flow_Separator =>
            P.Levels.Top.State := After_Param_Sep'Access;
            P.Current := Lexer.Next_Token (P.L);
            return False;
         when Lexer.Params_End =>
            E := Event'(Start_Position => P.Current.Start_Pos,
                        End_Position   => P.Current.End_Pos,
                        Kind => Annotation_End);
            P.Current := Lexer.Next_Token (P.L);
            P.Levels.Pop;
            return True;
         when Lexer.Flow_Scalar_Token_Kind | Lexer.Map_Key_Ind |
              Lexer.Anchor | Lexer.Alias | Lexer.Annotation |
              Lexer.Flow_Map_Start | Lexer.Flow_Seq_Start =>
            raise Parser_Error with "Missing ','";
         when others =>
            raise Parser_Error with "Unexpected token (expected ',' or ')'): " &
              P.Current.Kind'Img;
      end case;
   end After_Param;

   function After_Annotation (P : in out Implementation'Class; E : out Event)
                              return Boolean is
   begin
      E := Event'(Start_Position => P.Current.Start_Pos,
                  End_Position => P.Current.Start_Pos,
                  Kind => Annotation_End);
      P.Levels.Top.State := Before_Node_Properties'Access;
      return True;
   end After_Annotation;

end Yaml.Parser;
