--  part of AdaYaml, (c) 2017 Felix Krause
--  released under the terms of the MIT license, see the file "copying.txt"

with Yaml.Events.Queue;
with Yaml.Destination;

package Yaml.Dom.Dumping is
   function To_Event_Queue (Document : Document_Reference)
                            return Events.Queue.Reference;

   procedure Dump (Document : Document_Reference;
                   Output : not null Destination.Pointer);
end Yaml.Dom.Dumping;
