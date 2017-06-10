with Ada.Directories; use Ada.Directories;
with Ada.Text_IO; use Ada.Text_IO;
with Yaml.Sources.Files;
with Yaml.Events;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AUnit.Assertions; use AUnit.Assertions;

package body Yaml.Parsing.Event_Test is
   procedure Register_Tests (T : in out TC) is
      procedure Add_Test (Directory_Entry : Directory_Entry_Type) is
         Title_File : File_Type;
         use AUnit.Test_Cases.Registration;
         Dir_Name : constant String := Simple_Name (Directory_Entry);
      begin
         if Dir_Name /= "." and Dir_Name /= ".." and Dir_Name /= "meta"
           and Dir_Name /= "tags" and Dir_Name /= "name" then
            Open (Title_File, In_File,
                  Compose (Full_Name (Directory_Entry), "==="));
            if Exists (Compose (Full_Name (Directory_Entry), "error")) then
               Register_Routine (T, Execute_Error_Test'Access,
                                 '[' & Dir_Name & "] " & Get_Line (Title_File));
            else
               Register_Routine (T, Execute_Next_Test'Access,
                                 '[' & Dir_Name & "] " & Get_Line (Title_File));
            end if;
            Close (Title_File);
            T.Test_Cases.Append (Simple_Name (Directory_Entry));
         end if;
      end Add_Test;

   begin
      Search ("yaml-test-suite", "", (Directory => True, others => False),
              Add_Test'Access);
      T.Cur := 1;
   end Register_Tests;

   function Name (T : TC) return Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("YAML test suite (from GitHub)");
   end Name;

   procedure Execute_Next_Test (T : in out Test_Cases.Test_Case'Class) is
      Test_Dir : constant String :=
        Compose ("yaml-test-suite", TC (T).Test_Cases.Element (TC (T).Cur));
      P : Parser;
      Expected : File_Type;
      Output : Unbounded_String;
   begin
      TC (T).Cur := TC (T).Cur + 1;
      Parse (P, Sources.Files.As_Source (Compose (Test_Dir, "in.yaml")));
      Open (Expected, In_File, Compose (Test_Dir, "test.event"));
      loop
         declare
            Expected_Event : constant String := Get_Line (Expected);
            Actual : constant Events.Event := Streams.Next (P);
            Actual_Event : constant String := Events.To_String (Actual);
            use type Events.Event_Kind;
         begin
            if Expected_Event = Actual_Event then
               Append (Output, Actual_Event & Character'Val (10));
            else
               Append (Output, "--- " & Actual_Event & Character'Val (10));
               Append (Output, "+++ " & Expected_Event & Character'Val (10));
               Assert (False, "Actual events do not match expected events:" &
                         Character'Val (10) & Character'Val (10) &
                         To_String (Output));
            end if;
            exit when Actual.Kind = Events.Stream_End;
            if End_Of_File (Expected) then
               Assert (False, "More events generated than expected");
            end if;
         end;
      end loop;
      Close (Expected);
   exception when others =>
         Close (Expected);
         raise;
   end Execute_Next_Test;

   procedure Execute_Error_Test (T : in out Test_Cases.Test_Case'Class) is
      Test_Dir : constant String :=
        Compose ("yaml-test-suite", TC (T).Test_Cases.Element (TC (T).Cur));
      P : Parser;
      Output : Unbounded_String;
      Cur : Events.Event;
      Expected_Error : File_Type;
      use type Events.Event_Kind;
   begin
      TC (T).Cur := TC (T).Cur + 1;
      Parse (P, Sources.Files.As_Source (Compose (Test_Dir, "in.yaml")));
      loop
         Cur := Streams.Next (P);
         Append (Output, Events.To_String (Cur) & Character'Val (10));
         exit when Cur.Kind = Events.Stream_End;
      end loop;
      Open (Expected_Error, In_File, Compose (Test_Dir, "error"));
      declare
         Expected_Message : constant String :=
           (if End_Of_File (Expected_Error) then "" else
                 Get_Line (Expected_Error));
      begin
         Close (Expected_Error);
         Assert (False, "Parsed without error; expected error: " &
                   Expected_Message & Character'Val (10) & "Output: " &
                Character'Val (10) & Character'Val (10) & To_String (Output));
      end;
   exception when Lexer_Error | Parser_Error =>
         null;
   end Execute_Error_Test;


end Yaml.Parsing.Event_Test;
