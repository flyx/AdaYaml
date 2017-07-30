--  part of AdaYaml, (c) 2017 Felix Krause
--  released under the terms of the MIT license, see the file "copying.txt"

private with Ada.Finalization;

package Yaml.Event_Queue is
   --  raised when trying to manipulate a queue while a Stream_Instance exists
   --  for that queue.
   State_Error : exception;

   type Instance is new Refcount_Base with private;
   type Reference (Data : not null access Instance) is tagged private with
     Implicit_Dereference => Data;

   procedure Append (Object : in out Instance; E : Event);
   function Length (Object : in Instance) return Natural;
   function First (Object : in Instance) return Event;
   procedure Dequeue (Object : in out Instance);

   function New_Queue return Reference;

   type Stream_Instance is new Refcount_Base with private;
   type Stream_Reference (Data : not null access Stream_Instance) is
     tagged private with Implicit_Dereference => Data;

   function Next (Object : in out Stream_Instance) return Event;

   package Iteration is
      --  must be in child package so that it is not a dispatching operation
      function As_Stream (Object : not null access Instance)
                          return Stream_Reference;
   end Iteration;
private
   type Event_Array is array (Positive range <>) of Event;
   type Event_Array_Access is access Event_Array;

   type Reference (Data : not null access Instance) is new
     Ada.Finalization.Controlled with null record;

   overriding procedure Adjust (Object : in out Reference);
   overriding procedure Finalize (Object : in out Reference);

   type Instance is new Refcount_Base with record
      First_Pos : Positive := 1;
      Stream_Count, Length : Natural := 0;
      Data : not null Event_Array_Access := new Event_Array (1 .. 256);
   end record;

   overriding procedure Finalize (Object : in out Instance);

   type Instance_Pointer is access all Instance;

   type Stream_Instance is new Refcount_Base with record
      Buffer : not null access Instance;
      Offset : Natural := 0;
   end record;

   overriding procedure Finalize (Object : in out Stream_Instance);

   type Stream_Reference (Data : not null access Stream_Instance) is
     new Ada.Finalization.Controlled with null record;

   overriding procedure Adjust (Object : in out Stream_Reference);
   overriding procedure Finalize (Object : in out Stream_Reference);

end Yaml.Event_Queue;
